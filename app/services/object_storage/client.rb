# frozen_string_literal: true

require "aws-sdk-s3"

module ObjectStorage
  class Client
    class Error < StandardError; end

    def initialize(
      bucket: ENV.fetch("AWS_BUCKET", "github-ingest"),
      endpoint: ENV["AWS_ENDPOINT"],
      region: ENV.fetch("AWS_REGION", "us-east-1"),
      access_key_id: ENV["AWS_ACCESS_KEY_ID"],
      secret_access_key: ENV["AWS_SECRET_ACCESS_KEY"],
      client: nil
    )
      @bucket = bucket
      @client = client || build_client(
        endpoint: endpoint,
        region: region,
        access_key_id: access_key_id,
        secret_access_key: secret_access_key
      )
    end

    def put(key, body, content_type:)
      @client.put_object(
        bucket: @bucket,
        key: key,
        body: body,
        content_type: content_type
      )
      key
    rescue Aws::S3::Errors::ServiceError => e
      raise Error, "put failed for #{key}: #{e.message}"
    end

    def exists?(key)
      @client.head_object(bucket: @bucket, key: key)
      true
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
      false
    rescue Aws::S3::Errors::ServiceError => e
      raise Error, "exists? failed for #{key}: #{e.message}"
    end

    attr_reader :bucket

    private

    def build_client(endpoint:, region:, access_key_id:, secret_access_key:)
      options = {
        region: region,
        access_key_id: access_key_id,
        secret_access_key: secret_access_key,
        force_path_style: true
      }
      options[:endpoint] = endpoint if endpoint.present?
      Aws::S3::Client.new(options)
    end
  end
end
