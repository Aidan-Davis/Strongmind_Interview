# frozen_string_literal: true

module Ingest
  # Enriches a PushEvent with actor + repository records, using URL fetches and a TTL cache.
  class EnrichPushEvent
    CACHE_TTL = ENV.fetch("ENRICHMENT_CACHE_TTL_HOURS", "24").to_i.hours

    def initialize(push_event, client: Github::ApiClient.new, cache_ttl: CACHE_TTL)
      @push_event = push_event
      @client = client
      @cache_ttl = cache_ttl
    end

    def self.call(...)
      new(...).call
    end

    def call
      return @push_event if @push_event.enrichment_status == "enriched"

      raw = (@push_event.raw_payload || {}).with_indifferent_access
      actor = resolve_actor(raw[:actor])
      repository = resolve_repository(raw[:repo])

      @push_event.update!(
        actor: actor,
        repository_record: repository,
        enrichment_status: "enriched"
      )

      log("enriched", push_event_id: @push_event.id, actor_id: actor.id, repository_id: repository.id)
      @push_event
    end

    private

    def resolve_actor(actor_data)
      actor_data = (actor_data || {}).with_indifferent_access
      github_id = actor_data[:id]
      raise ArgumentError, "actor id missing from payload" if github_id.blank?

      existing = Actor.find_by(github_id: github_id)
      if existing&.cache_fresh?(ttl: @cache_ttl)
        log("actor_cache_hit", github_id: github_id, login: existing.login)
        ensure_avatar!(existing)
        return existing
      end

      url = actor_data[:url].presence || "https://api.github.com/users/#{actor_data[:login]}"
      log("actor_fetch", github_id: github_id, url: url)
      result = @client.fetch_json(url)
      wait_if_needed!(result.rate_limit)
      body = normalize_body(result.body)

      Actor.find_or_initialize_by(github_id: body.fetch("id")).tap do |actor|
        actor.login = body.fetch("login")
        actor.avatar_url = body["avatar_url"]
        actor.profile_json = body
        actor.fetched_at = Time.current
        actor.save!
        ensure_avatar!(actor)
      end
    end

    def resolve_repository(repo_data)
      repo_data = (repo_data || {}).with_indifferent_access
      github_id = repo_data[:id]
      raise ArgumentError, "repository id missing from payload" if github_id.blank?

      existing = Repository.find_by(github_id: github_id)
      if existing&.cache_fresh?(ttl: @cache_ttl)
        log("repo_cache_hit", github_id: github_id, full_name: existing.full_name)
        return existing
      end

      url = repo_data[:url].presence
      raise ArgumentError, "repository url missing from payload" if url.blank?

      log("repo_fetch", github_id: github_id, url: url)
      result = @client.fetch_json(url)
      wait_if_needed!(result.rate_limit)
      body = normalize_body(result.body)

      Repository.find_or_initialize_by(github_id: body.fetch("id")).tap do |repo|
        repo.full_name = body["full_name"].presence || repo_data[:name]
        repo.html_url = body["html_url"]
        repo.profile_json = body
        repo.fetched_at = Time.current
        repo.save!
      end
    end

    def normalize_body(body)
      raise Github::ApiClient::Error, "expected JSON object from GitHub" unless body.is_a?(Hash)

      body.deep_stringify_keys
    end

    def wait_if_needed!(rate_limit)
      return unless rate_limit&.should_wait?

      wait = [ rate_limit.seconds_until_reset, 1 ].max
      log("preemptive_rate_limit_wait", wait_seconds: wait, remaining: rate_limit.remaining)
      sleep wait
    end

    def ensure_avatar!(actor)
      ObjectStorage::AvatarUploader.call(actor)
    rescue ObjectStorage::Client::Error, Faraday::Error => e
      log("avatar_storage_failed", actor_id: actor.id, error: e.message)
    end

    def log(event, **fields)
      AppLog.info("enrich", event, **fields)
    end
  end
end
