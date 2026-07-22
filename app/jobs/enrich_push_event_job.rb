# frozen_string_literal: true

class EnrichPushEventJob < ApplicationJob
  queue_as :enrichment

  retry_on Faraday::Error, wait: 30.seconds, attempts: 5
  retry_on Github::ApiClient::Error, wait: 30.seconds, attempts: 3

  discard_on ActiveJob::DeserializationError

  def perform(push_event_id)
    push_event = PushEvent.find_by(id: push_event_id)
    unless push_event
      AppLog.warn("enrich", "missing_push_event", push_event_id: push_event_id)
      return
    end

    if push_event.enrichment_status == "enriched"
      AppLog.info("enrich", "already_enriched", push_event_id: push_event_id)
      return
    end

    Ingest::EnrichPushEvent.call(push_event)
  rescue ArgumentError => e
    AppLog.error("enrich", "permanent_failure", push_event_id: push_event_id, error: e.message)
    push_event&.update!(enrichment_status: "failed")
  rescue Github::ApiClient::RateLimited => e
    wait = [ e.rate_limit.seconds_until_reset, 5 ].max
    AppLog.warn(
      "enrich",
      "rate_limited",
      push_event_id: push_event_id,
      wait_seconds: wait,
      remaining: e.rate_limit.remaining
    )
    self.class.set(wait: wait.seconds).perform_later(push_event_id)
  rescue Faraday::Error, Github::ApiClient::Error
    raise
  rescue StandardError => e
    AppLog.error("enrich", "failed", push_event_id: push_event_id, error: e.class.name, message: e.message)
    push_event&.update!(enrichment_status: "failed")
    raise
  end
end
