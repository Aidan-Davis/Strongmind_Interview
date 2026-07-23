# frozen_string_literal: true

RSpec.describe EnrichPushEventJob, type: :job do
  include ActiveJob::TestHelper

  let!(:push_event) do
    PushEvent.create!(
      github_event_id: "evt-job-1",
      repository_id: 1,
      raw_payload: {
        "actor" => { "id" => 1, "login" => "a", "url" => "https://api.github.com/users/a" },
        "repo" => { "id" => 1, "name" => "a/b", "url" => "https://api.github.com/repos/a/b" }
      },
      enrichment_status: "pending"
    )
  end

  it "delegates to the enrichment service" do
    expect(Ingest::EnrichPushEvent).to receive(:call).with(push_event)
    described_class.perform_now(push_event.id)
  end

  it "marks permanent ArgumentError failures as failed" do
    allow(Ingest::EnrichPushEvent).to receive(:call).and_raise(ArgumentError, "actor id missing from payload")

    described_class.perform_now(push_event.id)

    expect(push_event.reload.enrichment_status).to eq("failed")
  end

  it "requeues when GitHub rate limits the request" do
    allow(Ingest::EnrichPushEvent).to receive(:call).and_raise(
      Github::ApiClient::RateLimited.new(
        "limited",
        rate_limit: Github::RateLimit.new(remaining: 0, reset_at: 2.minutes.from_now)
      )
    )

    expect {
      described_class.perform_now(push_event.id)
    }.to have_enqueued_job(described_class).with(push_event.id)

    expect(push_event.reload.enrichment_status).to eq("pending")
  end
end
