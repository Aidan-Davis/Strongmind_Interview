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

  describe "rate-limit backoff" do
    let(:low_rate_limit) { Github::RateLimit.new(remaining: 1, reset_at: 40.minutes.from_now) }

    it "does not sleep in non-blocking (one-shot) mode when preemptively rate limited" do
      runner = described_class.new(client: client, poll_interval: 0, idle_interval: 0, blocking: false)
      allow(client).to receive(:fetch_events).and_return(
        Github::EventsClient::Result.new(events: [ push_event ], etag: "W/\"1\"", rate_limit: low_rate_limit, not_modified: false)
      )

      expect(runner).not_to receive(:sleep)

      result = runner.run_once

      expect(result[:created]).to eq(1)
    end

    it "does not sleep in non-blocking (one-shot) mode when the fetch itself is rate limited" do
      runner = described_class.new(client: client, poll_interval: 0, idle_interval: 0, blocking: false)
      allow(client).to receive(:fetch_events).and_raise(
        Github::EventsClient::RateLimited.new("limited", rate_limit: low_rate_limit)
      )

      expect(runner).not_to receive(:sleep)

      result = runner.run_once

      expect(result[:rate_limited]).to be(true)
    end

    it "still sleeps in blocking (continuous) mode when rate limited" do
      runner = described_class.new(client: client, poll_interval: 0, idle_interval: 0, blocking: true)
      allow(client).to receive(:fetch_events).and_raise(
        Github::EventsClient::RateLimited.new("limited", rate_limit: low_rate_limit)
      )
      allow(runner).to receive(:sleep)

      runner.run_once

      expect(runner).to have_received(:sleep)
    end
  end
end
