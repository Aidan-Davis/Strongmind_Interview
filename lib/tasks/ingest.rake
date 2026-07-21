# frozen_string_literal: true

namespace :ingest do
  desc "Ingest GitHub Push events (stub until the ingest pipeline is implemented)"
  task run: :environment do
    message = "[ingest] Stub OK — Docker wiring works. Pipeline lands in a later step."
    Rails.logger.info(message)
    puts message
  end
end
