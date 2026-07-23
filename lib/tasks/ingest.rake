# frozen_string_literal: true

namespace :ingest do
  desc "Ingest GitHub Push events (INGEST_MODE=once|loop, default once)"
  task run: :environment do
    mode = ENV.fetch("INGEST_MODE", "once")
    continuous = %w[loop continuous].include?(mode)
    # One-shot mode must return promptly for reviewers (docker compose run --rm
    # ingest), so it never blocks on rate-limit backoff; the continuous worker
    # is long-running and can safely sleep between polls.
    runner = Ingest::PushEventsRunner.new(blocking: continuous)

    if continuous
      runner.run_loop
    else
      stats = runner.run_once
      AppLog.info("ingest", "done", **stats)
    end
  end
end
