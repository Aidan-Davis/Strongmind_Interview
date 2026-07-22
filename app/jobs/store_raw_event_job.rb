# frozen_string_literal: true

class StoreRawEventJob < ApplicationJob
  queue_as :default

  retry_on ObjectStorage::Client::Error, wait: 15.seconds, attempts: 5
  retry_on Faraday::Error, wait: 15.seconds, attempts: 5

  def perform(push_event_id)
    push_event = PushEvent.find_by(id: push_event_id)
    unless push_event
      AppLog.warn("storage", "missing_push_event", push_event_id: push_event_id)
      return
    end

    ObjectStorage::RawEventUploader.call(push_event)
  end
end
