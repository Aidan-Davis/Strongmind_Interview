# frozen_string_literal: true

# Stub enrichment job — full actor/repo fetch lands in the next step.
class EnrichPushEventJob < ApplicationJob
  queue_as :enrichment

  def perform(push_event_id)
    Rails.logger.info("[enrich] stub_received push_event_id=#{push_event_id}")
  end
end
