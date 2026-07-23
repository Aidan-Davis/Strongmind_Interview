# frozen_string_literal: true

RSpec.describe ObjectStorage::AvatarUploader do
  let(:storage) do
    Class.new do
      attr_reader :objects

      def initialize
        @objects = {}
      end

      def put(key, body, content_type:)
        @objects[key] = { body: body, content_type: content_type }
        key
      end

      def exists?(key)
        @objects.key?(key)
      end
    end.new
  end

  let!(:actor) do
    Actor.create!(
      github_id: 99,
      login: "octocat",
      avatar_url: "https://avatars.example/u/99.png",
      profile_json: { "id" => 99 }
    )
  end

  it "downloads the avatar once and stores a durable key" do
    stub_request(:get, "https://avatars.example/u/99.png")
      .to_return(status: 200, body: "img-bytes", headers: { "Content-Type" => "image/png" })

    key = described_class.call(actor, storage: storage)

    expect(key).to eq("avatars/99.png")
    expect(actor.reload.avatar_object_key).to eq(key)
    expect(storage.objects[key][:body]).to eq("img-bytes")
  end

  it "does not re-download when avatar_object_key is already set" do
    actor.update!(avatar_object_key: "avatars/99.png")

    expect {
      described_class.call(actor, storage: storage)
    }.not_to raise_error

    expect(a_request(:get, "https://avatars.example/u/99.png")).not_to have_been_made
  end
end
