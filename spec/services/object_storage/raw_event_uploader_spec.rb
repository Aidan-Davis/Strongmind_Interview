# frozen_string_literal: true

RSpec.describe ObjectStorage::RawEventUploader do
  let(:storage) do
    Class.new do
      attr_reader :objects, :put_calls

      def initialize
        @objects = {}
        @put_calls = 0
      end

      def put(key, body, content_type:)
        @put_calls += 1
        @objects[key] = { body: body, content_type: content_type }
        key
      end

      def exists?(key)
        @objects.key?(key)
      end
    end.new
  end

  let!(:push_event) do
    PushEvent.create!(
      github_event_id: "evt-raw-1",
      repository_id: 1,
      raw_payload: { "id" => "evt-raw-1", "type" => "PushEvent" },
      enrichment_status: "pending"
    )
  end

  it "uploads raw JSON once and stores the durable key" do
    key = described_class.call(push_event, storage: storage)

    expect(key).to eq("raw-events/evt-raw-1.json")
    expect(push_event.reload.raw_object_key).to eq(key)
    expect(storage.objects[key][:content_type]).to eq("application/json")
    expect(storage.put_calls).to eq(1)
  end

  it "skips re-upload when the object already exists" do
    storage.put("raw-events/evt-raw-1.json", "{}", content_type: "application/json")
    put_calls_before = storage.put_calls

    key = described_class.call(push_event, storage: storage)

    expect(key).to eq("raw-events/evt-raw-1.json")
    expect(push_event.reload.raw_object_key).to eq(key)
    expect(storage.put_calls).to eq(put_calls_before)
  end
end
