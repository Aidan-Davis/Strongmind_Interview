# frozen_string_literal: true

RSpec.describe Ingest::PushEventsRunner do
  let(:push_event) do
    {
      "id" => "evt-1",
      "type" => "PushEvent",
      "repo" => { "id" => 42, "name" => "o/r", "url" => "https://api.github.com/repos/o/r" },
      "payload" => { "push_id" => 9, "ref" => "refs/heads/main", "head" => "a", "before" => "b" },
      "actor" => { "id" => 7, "login" => "octo", "url" => "https://api.github.com/users/octo" }
    }
  end
  let(:other_event) { { "id" => "x", "type" => "WatchEvent" } }
  let(:client) { instance_double(Github::EventsClient) }
  let(:runner) { described_class.new(client: client, poll_interval: 0, idle_interval: 0) }

  def events_result(events)
    Github::EventsClient::Result.new(
      events: events,
      etag: "W/\"1\"",
      rate_limit: Github::RateLimit.new(remaining: 50),
      not_modified: false
    )
  end

  it "persists only PushEvents and enqueues enrichment + raw storage" do
    allow(client).to receive(:fetch_events).and_return(events_result([ push_event, other_event ]))

    expect { runner.run_once }.to change(PushEvent, :count).by(1)

    expect(EnrichPushEventJob).to have_been_enqueued.with(PushEvent.last.id)
    expect(StoreRawEventJob).to have_been_enqueued.with(PushEvent.last.id)
    expect(PushEvent.find_by!(github_event_id: "evt-1")).to have_attributes(
      repository_id: 42,
      push_id: 9,
      ref: "refs/heads/main",
      enrichment_status: "pending"
    )
  end

  it "is idempotent for duplicate event ids" do
    allow(client).to receive(:fetch_events).and_return(events_result([ push_event ]))

    runner.run_once
    clear_enqueued_jobs

    expect { runner.run_once }.not_to change(PushEvent, :count)
    expect(EnrichPushEventJob).not_to have_been_enqueued
    expect(StoreRawEventJob).not_to have_been_enqueued
  end

  it "skips malformed push events without raising" do
    bad = push_event.merge("id" => nil)
    allow(client).to receive(:fetch_events).and_return(events_result([ bad ]))

    expect { runner.run_once }.not_to raise_error
    expect(PushEvent.count).to eq(0)
  end
end
