# frozen_string_literal: true

module ObjectStorage
  # Persists raw GitHub event JSON under a durable, idempotent key.
  class RawEventUploader
    def initialize(push_event, storage: Client.new)
      @push_event = push_event
      @storage = storage
    end

    def self.call(...)
      new(...).call
    end

    def call
      return @push_event.raw_object_key if @push_event.raw_object_key.present?

      key = self.class.key_for(@push_event.github_event_id)
      if @storage.exists?(key)
        @push_event.update!(raw_object_key: key)
        log("raw_exists", key: key, push_event_id: @push_event.id)
        return key
      end

      body = JSON.generate(@push_event.raw_payload)
      @storage.put(key, body, content_type: "application/json")
      @push_event.update!(raw_object_key: key)
      log("raw_uploaded", key: key, push_event_id: @push_event.id)
      key
    end

    def self.key_for(github_event_id)
      "raw-events/#{github_event_id}.json"
    end

    private

    def log(event, **fields)
      payload = fields.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      Rails.logger.info("[storage] #{event} #{payload}")
    end
  end
end
