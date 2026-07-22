# frozen_string_literal: true

namespace :ingest do
  desc "Ingest GitHub Push events (INGEST_MODE=once|loop, default once)"
  task run: :environment do
    mode = ENV.fetch("INGEST_MODE", "once")
    runner = Ingest::PushEventsRunner.new

    case mode
    when "loop", "continuous"
      runner.run_loop
    else
      stats = runner.run_once
      AppLog.info("ingest", "done", **stats)
    end
  end
end
