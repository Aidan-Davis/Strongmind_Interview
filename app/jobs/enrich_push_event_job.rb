# frozen_string_literal: true

class EnrichPushEventJob < ApplicationJob
  queue_as :enrichment

  retry_on Faraday::Error, wait: 30.seconds, attempts: 5
  retry_on Github::ApiClient::Error, wait: 30.seconds, attempts: 3

  discard_on ActiveJob::DeserializationError

  def perform(push_event_id)
    push_event = PushEvent.find_by(id: push_event_id)
    unless push_event
      Rails.logger.warn("[enrich] missing_push_event push_event_id=#{push_event_id}")
      return
    end

    if push_event.enrichment_status == "enriched"
      Rails.logger.info("[enrich] already_enriched push_event_id=#{push_event_id}")
      return
    end

    Ingest::EnrichPushEvent.call(push_event)
  rescue ArgumentError => e
    Rails.logger.error("[enrich] permanent_failure push_event_id=#{push_event_id} error=#{e.message}")
    push_event&.update!(enrichment_status: "failed")
  rescue Github::ApiClient::RateLimited => e
    wait = [ e.rate_limit.seconds_until_reset, 5 ].max
    Rails.logger.warn(
      "[enrich] rate_limited push_event_id=#{push_event_id} wait_seconds=#{wait} remaining=#{e.rate_limit.remaining.inspect}"
    )
    # Re-queue after reset instead of busy-retrying and amplifying load.
    self.class.set(wait: wait.seconds).perform_later(push_event_id)
  rescue Faraday::Error, Github::ApiClient::Error
    raise
  rescue StandardError => e
    Rails.logger.error("[enrich] failed push_event_id=#{push_event_id} error=#{e.class}: #{e.message}")
    push_event&.update!(enrichment_status: "failed")
    raise
  end
end
