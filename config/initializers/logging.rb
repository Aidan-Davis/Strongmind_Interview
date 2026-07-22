# frozen_string_literal: true

# Send Rails logs to stdout/stderr so `docker compose logs -f` shows system behavior.
if ENV["RAILS_LOG_TO_STDOUT"].present?
  $stdout.sync = true
  $stderr.sync = true

  stdout_logger = ActiveSupport::Logger.new($stdout)
  stdout_logger.formatter = Logger::Formatter.new
  Rails.logger = ActiveSupport::TaggedLogging.new(stdout_logger)
  Rails.logger.level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Keep operator logs readable in Compose (avoid drowning in SQL debug noise).
  if defined?(ActiveRecord::Base)
    ActiveRecord::Base.logger = Rails.logger
  end
end
