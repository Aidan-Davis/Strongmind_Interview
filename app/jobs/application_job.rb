# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3
  discard_on ActiveJob::DeserializationError

  around_perform do |job, block|
    AppLog.info(
      "job",
      "start",
      job: job.class.name,
      job_id: job.job_id,
      queue: job.queue_name,
      arguments: job.arguments.inspect
    )
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    block.call
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
    AppLog.info("job", "success", job: job.class.name, job_id: job.job_id, elapsed_ms: elapsed_ms)
  rescue StandardError => e
    AppLog.error(
      "job",
      "failure",
      job: job.class.name,
      job_id: job.job_id,
      error: e.class.name,
      message: e.message
    )
    raise
  end
end
