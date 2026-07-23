# frozen_string_literal: true

RSpec.describe Ingest::EnrichPushEvent do
  let(:raw_payload) do
    {
      "actor" => {
        "id" => 7,
        "login" => "octocat",
        "url" => "https://api.github.com/users/octocat",
        "avatar_url" => "https://avatars.example/u/7"
      },
      "repo" => {
        "id" => 42,
        "name" => "octocat/hello",
        "url" => "https://api.github.com/repos/octocat/hello"
      }
    }
  end
  let!(:push_event) do
    PushEvent.create!(
      github_event_id: "evt-enrich-1",
      repository_id: 42,
      push_id: 1,
      ref: "refs/heads/main",
      head: "a",
      before: "b",
      raw_payload: raw_payload,
      enrichment_status: "pending"
    )
  end
  let(:client) { instance_double(Github::ApiClient) }

  before do
    allow(ObjectStorage::AvatarUploader).to receive(:call)
  end

  it "fetches actor/repo, persists them, and marks the event enriched" do
    allow(client).to receive(:fetch_json).with("https://api.github.com/users/octocat").and_return(
      Github::ApiClient::Result.new(
        body: { "id" => 7, "login" => "octocat", "avatar_url" => "https://avatars.example/u/7" },
        rate_limit: Github::RateLimit.new(remaining: 50)
      )
    )
    allow(client).to receive(:fetch_json).with("https://api.github.com/repos/octocat/hello").and_return(
      Github::ApiClient::Result.new(
        body: { "id" => 42, "full_name" => "octocat/hello", "html_url" => "https://github.com/octocat/hello" },
        rate_limit: Github::RateLimit.new(remaining: 49)
      )
    )

    described_class.call(push_event, client: client)
    push_event.reload

    expect(push_event.enrichment_status).to eq("enriched")
    expect(push_event.actor.login).to eq("octocat")
    expect(push_event.repository_record.full_name).to eq("octocat/hello")
    expect(ObjectStorage::AvatarUploader).to have_received(:call).with(push_event.actor)
  end

  it "uses cached actor/repo within TTL and skips HTTP fetches" do
    actor = Actor.create!(
      github_id: 7,
      login: "octocat",
      avatar_url: "https://avatars.example/u/7",
      profile_json: { "id" => 7 },
      fetched_at: Time.current
    )
    repo = Repository.create!(
      github_id: 42,
      full_name: "octocat/hello",
      profile_json: { "id" => 42 },
      fetched_at: Time.current
    )

    expect(client).not_to receive(:fetch_json)

    described_class.call(push_event, client: client)
    push_event.reload

    expect(push_event.actor_id).to eq(actor.id)
    expect(push_event.repository_record_id).to eq(repo.id)
    expect(push_event.enrichment_status).to eq("enriched")
  end
end
