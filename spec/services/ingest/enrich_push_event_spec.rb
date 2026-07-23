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

  it "escapes special characters in the login when building the fallback actor URL" do
    push_event.update!(
      raw_payload: raw_payload.deep_merge(
        "actor" => { "id" => 99, "login" => "github-actions[bot]", "url" => nil, "avatar_url" => nil }
      )
    )

    expect(client).to receive(:fetch_json).with("https://api.github.com/users/github-actions%5Bbot%5D").and_return(
      Github::ApiClient::Result.new(
        body: { "id" => 99, "login" => "github-actions[bot]" },
        rate_limit: Github::RateLimit.new(remaining: 50)
      )
    )
    allow(client).to receive(:fetch_json).with("https://api.github.com/repos/octocat/hello").and_return(
      Github::ApiClient::Result.new(
        body: { "id" => 42, "full_name" => "octocat/hello", "html_url" => "https://github.com/octocat/hello" },
        rate_limit: Github::RateLimit.new(remaining: 49)
      )
    )

    expect { described_class.call(push_event, client: client) }.not_to raise_error

    push_event.reload
    expect(push_event.enrichment_status).to eq("enriched")
    expect(push_event.actor.login).to eq("github-actions[bot]")
  end

  it "raises instead of sleeping when the quota is nearly exhausted, without losing the fetch already made" do
    allow(client).to receive(:fetch_json).with("https://api.github.com/users/octocat").and_return(
      Github::ApiClient::Result.new(
        body: { "id" => 7, "login" => "octocat", "avatar_url" => "https://avatars.example/u/7" },
        rate_limit: Github::RateLimit.new(remaining: 2, reset_at: 10.minutes.from_now)
      )
    )

    expect(client).not_to receive(:fetch_json).with("https://api.github.com/repos/octocat/hello")

    expect { described_class.call(push_event, client: client) }.to raise_error(Github::ApiClient::RateLimited)

    # The actor fetch that already succeeded is persisted (and cached for the
    # next attempt) rather than thrown away; only the push_event itself stays
    # pending so the job can re-enqueue and pick up where it left off.
    expect(Actor.find_by(github_id: 7)).to have_attributes(login: "octocat")
    expect(push_event.reload.enrichment_status).to eq("pending")
  end
end
