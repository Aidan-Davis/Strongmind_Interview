# frozen_string_literal: true

module Ingest
  # Polls GitHub public events, persists PushEvents idempotently, enqueues enrichment.
  class PushEventsRunner
    DEFAULT_POLL_INTERVAL = Integer(ENV.fetch("INGEST_POLL_INTERVAL_SECONDS", "60"))
    DEFAULT_IDLE_INTERVAL = Integer(ENV.fetch("INGEST_IDLE_INTERVAL_SECONDS", "90"))

    def initialize(client: Github::EventsClient.new, poll_interval: DEFAULT_POLL_INTERVAL, idle_interval: DEFAULT_IDLE_INTERVAL)
      @client = client
      @poll_interval = poll_interval
      @idle_interval = idle_interval
      @etag = nil
    end

    def run_once
      log("poll_start", etag: @etag.present?)
      result = @client.fetch_events(etag: @etag)
      @etag = result.etag if result.etag.present?

      maybe_wait_for_rate_limit!(result.rate_limit)

      if result.not_modified
        log("not_modified", remaining: result.rate_limit&.remaining)
        return { seen: 0, created: 0, skipped: 0, enqueued: 0, not_modified: true }
      end

      stats = process_events(result.events)
      log(
        "poll_complete",
        seen: stats[:seen],
        created: stats[:created],
        skipped: stats[:skipped],
        enqueued: stats[:enqueued],
        remaining: result.rate_limit&.remaining
      )
      stats.merge(not_modified: false)
    rescue Github::EventsClient::RateLimited => e
      wait = [ e.rate_limit.seconds_until_reset, 5 ].max
      log("rate_limited", wait_seconds: wait, remaining: e.rate_limit.remaining)
      sleep wait
      { seen: 0, created: 0, skipped: 0, enqueued: 0, rate_limited: true }
    rescue Faraday::Error, Github::EventsClient::Error => e
      log("transient_error", error: e.class.name, message: e.message)
      sleep @poll_interval
      { seen: 0, created: 0, skipped: 0, enqueued: 0, error: e.message }
    end

    def run_loop
      log("loop_start", poll_interval: @poll_interval, idle_interval: @idle_interval)
      loop do
        stats = run_once
        interval = stats[:not_modified] || stats[:rate_limited] ? @idle_interval : @poll_interval
        sleep interval
      end
    end

    private

    def process_events(events)
      stats = { seen: 0, created: 0, skipped: 0, enqueued: 0 }

      Array(events).each do |event|
        type = event.is_a?(Hash) ? event["type"] || event[:type] : nil
        next unless type == "PushEvent"

        stats[:seen] += 1
        begin
          outcome = upsert_push_event!(event)
          stats[outcome[:status]] += 1
          stats[:enqueued] += 1 if outcome[:enqueued]
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          stats[:skipped] += 1
          log("malformed_event", error: e.message, event_id: event.is_a?(Hash) ? event["id"] : nil)
        end
      end

      stats
    end

    def upsert_push_event!(event)
      attrs = PushEventMapper.call(event)
      record = PushEvent.find_or_initialize_by(github_event_id: attrs[:github_event_id])
      was_new = record.new_record?

      if was_new
        record.assign_attributes(attrs.merge(enrichment_status: "pending"))
        record.save!
        StoreRawEventJob.perform_later(record.id)
        enqueue_enrichment!(record)
        { status: :created, enqueued: true }
      else
        # Duplicates are no-ops. Pending rows keep their status until enrichment runs;
        # Sidekiq retries cover transient enrichment failures without poll fan-out.
        { status: :skipped, enqueued: false }
      end
    end

    def enqueue_enrichment!(record)
      EnrichPushEventJob.perform_later(record.id)
    end

    def maybe_wait_for_rate_limit!(rate_limit)
      return unless rate_limit&.should_wait?

      wait = [ rate_limit.seconds_until_reset, 1 ].max
      log("preemptive_rate_limit_wait", wait_seconds: wait, remaining: rate_limit.remaining)
      sleep wait
    end

    def log(event, **fields)
      payload = fields.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      message = "[ingest] #{event}#{payload.present? ? " #{payload}" : ""}"
      Rails.logger.info(message)
      puts message
    end
  end
end
