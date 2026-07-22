# frozen_string_literal: true

module Github
  # Tracks GitHub REST API rate-limit headers and decides how long to sleep.
  class RateLimit
    LOW_REMAINING_THRESHOLD = 5

    attr_reader :remaining, :reset_at, :retry_after

    def initialize(remaining: nil, reset_at: nil, retry_after: nil)
      @remaining = remaining
      @reset_at = reset_at
      @retry_after = retry_after
    end

    def self.from_response(response)
      headers = response.headers
      remaining = headers["x-ratelimit-remaining"]&.to_i
      reset_epoch = headers["x-ratelimit-reset"]&.to_i
      reset_at = reset_epoch&.positive? ? Time.zone.at(reset_epoch) : nil
      retry_after = headers["retry-after"]&.to_i

      new(
        remaining: remaining,
        reset_at: reset_at,
        retry_after: (retry_after&.positive? ? retry_after : nil)
      )
    end

    def should_wait?
      return true if retry_after.to_i.positive?
      return true if remaining && remaining <= LOW_REMAINING_THRESHOLD && reset_at

      false
    end

    def seconds_until_reset
      return retry_after if retry_after.to_i.positive?
      return 0 unless reset_at

      [ (reset_at - Time.current).ceil, 0 ].max
    end
  end
end
