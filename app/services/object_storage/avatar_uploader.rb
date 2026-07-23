# frozen_string_literal: true

require "faraday"

module ObjectStorage
  # Downloads a contributor avatar once and stores it in object storage.
  class AvatarUploader
    # Bound avatar downloads so a slow/hung image host can't stall the worker.
    OPEN_TIMEOUT = Integer(ENV.fetch("AVATAR_HTTP_OPEN_TIMEOUT_SECONDS", "5"))
    READ_TIMEOUT = Integer(ENV.fetch("AVATAR_HTTP_TIMEOUT_SECONDS", "15"))

    def initialize(actor, storage: Client.new, http: nil)
      @actor = actor
      @storage = storage
      @http = http || default_http
    end

    def self.call(...)
      new(...).call
    end

    def call
      return @actor.avatar_object_key if @actor.avatar_object_key.present?
      return if @actor.avatar_url.blank?

      key = self.class.key_for(@actor.github_id, @actor.avatar_url)
      if @storage.exists?(key)
        @actor.update!(avatar_object_key: key)
        log("avatar_exists", key: key, actor_id: @actor.id)
        return key
      end

      response = @http.get(@actor.avatar_url)
      unless response.status == 200 && response.body.present?
        log("avatar_download_failed", status: response.status, actor_id: @actor.id)
        return nil
      end

      content_type = response.headers["content-type"].presence || "application/octet-stream"
      @storage.put(key, response.body, content_type: content_type)
      @actor.update!(avatar_object_key: key)
      log("avatar_uploaded", key: key, actor_id: @actor.id, bytes: response.body.bytesize)
      key
    end

    def self.key_for(github_id, avatar_url)
      ext = extension_for(avatar_url)
      "avatars/#{github_id}#{ext}"
    end

    def self.extension_for(avatar_url)
      path = URI.parse(avatar_url).path rescue ""
      ext = File.extname(path.to_s)
      return ext if ext.match?(/\A\.[a-zA-Z0-9]{1,5}\z/)

      ".img"
    end

    private

    def default_http
      Faraday.new do |f|
        f.options.open_timeout = OPEN_TIMEOUT
        f.options.timeout = READ_TIMEOUT
        f.adapter Faraday.default_adapter
      end
    end

    def log(event, **fields)
      AppLog.info("storage", event, **fields)
    end
  end
end
