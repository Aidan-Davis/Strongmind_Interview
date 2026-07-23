# frozen_string_literal: true

RSpec.describe ObjectStorage::Client do
  let(:s3) { instance_double(Aws::S3::Client) }
  let(:client) { described_class.new(bucket: "test-bucket", client: s3) }
  # What a MinIO/S3 outage actually raises - not an Aws::S3::Errors::ServiceError.
  let(:networking_error) { Seahorse::Client::NetworkingError.new(SocketError.new("getaddrinfo: unknown host")) }

  describe "#put" do
    it "returns the key on success" do
      allow(s3).to receive(:put_object).and_return(true)

      expect(client.put("k", "body", content_type: "application/json")).to eq("k")
    end

    it "wraps a connectivity outage as ObjectStorage::Client::Error so jobs can retry it" do
      allow(s3).to receive(:put_object).and_raise(networking_error)

      expect { client.put("k", "body", content_type: "application/json") }
        .to raise_error(ObjectStorage::Client::Error, /put failed for k/)
    end
  end

  describe "#exists?" do
    it "returns false when the object is missing" do
      allow(s3).to receive(:head_object).and_raise(Aws::S3::Errors::NotFound.new(nil, "missing"))

      expect(client.exists?("k")).to be(false)
    end

    it "wraps a connectivity outage as ObjectStorage::Client::Error" do
      allow(s3).to receive(:head_object).and_raise(networking_error)

      expect { client.exists?("k") }.to raise_error(ObjectStorage::Client::Error, /exists\? failed for k/)
    end
  end
end
