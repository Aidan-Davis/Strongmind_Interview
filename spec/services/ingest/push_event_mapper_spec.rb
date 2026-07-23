# frozen_string_literal: true

RSpec.describe Ingest::PushEventMapper do
  let(:event) do
    {
      "id" => "12345",
      "type" => "PushEvent",
      "repo" => { "id" => 99, "name" => "octo/hello", "url" => "https://api.github.com/repos/octo/hello" },
      "payload" => {
        "push_id" => 777,
        "ref" => "refs/heads/main",
        "head" => "abc123",
        "before" => "def456"
      },
      "actor" => { "id" => 1, "login" => "octocat", "url" => "https://api.github.com/users/octocat" }
    }
  end

  it "maps structured push attributes from a GitHub event" do
    attrs = described_class.call(event)

    expect(attrs).to include(
      github_event_id: "12345",
      repository_id: 99,
      push_id: 777,
      ref: "refs/heads/main",
      head: "abc123",
      before: "def456"
    )
    expect(attrs[:raw_payload]).to be_a(Hash)
  end

  it "raises when repository id is missing" do
    bad = event.merge("repo" => {}, "payload" => {})
    expect { described_class.call(bad) }.to raise_error(ArgumentError, /repository id/)
  end

  it "raises when event id is missing" do
    bad = event.merge("id" => nil)
    expect { described_class.call(bad) }.to raise_error(ArgumentError, /event id/)
  end
end
