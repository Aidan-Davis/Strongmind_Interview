# frozen_string_literal: true

require "uri"

module Ingest
  # Enriches a PushEvent with actor + repository records, using URL fetches and a TTL cache.
  class EnrichPushEvent
    CACHE_TTL = ENV.fetch("ENRICHMENT_CACHE_TTL_HOURS", "24").to_i.hours

    # GitHub's public events API returns `actor.url` verbatim for bot accounts with
    # *literal, unescaped* brackets, e.g. "https://api.github.com/users/github-actions[bot]"
    # (confirmed against the live API, not just our own fallback URL construction below).
    # That's not a valid URI and raises URI::InvalidURIError deep in Faraday. Escape only
    # the characters that are actually unsafe in a URI, leaving existing percent-encoding
    # and normal URL structure (: / ? # @ etc.) untouched.
    UNSAFE_URL_CHARS = %r{[^A-Za-z0-9\-._~:/?#@!$&'()*+,;=%]}

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

      url = sanitize_url(actor_data[:url].presence || "https://api.github.com/users/#{actor_data[:login]}")
      log("actor_fetch", github_id: github_id, url: url)
      result = @client.fetch_json(url)
      body = normalize_body(result.body)

      actor = Actor.find_or_initialize_by(github_id: body.fetch("id")).tap do |a|
        a.login = body.fetch("login")
        a.avatar_url = body["avatar_url"]
        a.profile_json = body
        a.fetched_at = Time.current
        a.save!
        ensure_avatar!(a)
      end

      # Check after persisting so a fetch that already succeeded isn't wasted;
      # the next attempt will hit the cache above instead of re-fetching.
      raise_if_rate_limited!(result.rate_limit)
      actor
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

      url = sanitize_url(url)
      log("repo_fetch", github_id: github_id, url: url)
      result = @client.fetch_json(url)
      body = normalize_body(result.body)

      repository = Repository.find_or_initialize_by(github_id: body.fetch("id")).tap do |repo|
        repo.full_name = body["full_name"].presence || repo_data[:name]
        repo.html_url = body["html_url"]
        repo.profile_json = body
        repo.fetched_at = Time.current
        repo.save!
      end

      raise_if_rate_limited!(result.rate_limit)
      repository
    end

    def sanitize_url(url)
      URI::DEFAULT_PARSER.escape(url.to_s, UNSAFE_URL_CHARS)
    end

    def normalize_body(body)
      raise Github::ApiClient::Error, "expected JSON object from GitHub" unless body.is_a?(Hash)

      body.deep_stringify_keys
    end

    # Signals rate-limit exhaustion instead of sleeping in-thread: Sidekiq runs
    # this job with concurrency 1, so a blocking sleep here would stall every
    # other queued job (including cheap raw-event uploads) for up to an hour.
    # Raising lets EnrichPushEventJob re-enqueue with a delay instead, freeing
    # the worker to process other jobs while waiting for the quota to reset.
    def raise_if_rate_limited!(rate_limit)
      return unless rate_limit&.should_wait?

      log("preemptive_rate_limit", wait_seconds: rate_limit.seconds_until_reset, remaining: rate_limit.remaining)
      raise Github::ApiClient::RateLimited.new(
        "GitHub rate limit nearly exhausted (remaining=#{rate_limit.remaining})",
        rate_limit: rate_limit
      )
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
