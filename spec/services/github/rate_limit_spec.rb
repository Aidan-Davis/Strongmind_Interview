# frozen_string_literal: true

RSpec.describe Github::RateLimit do
  describe ".from_response" do
    it "parses remaining, reset, and retry-after headers" do
      reset_at = 1.hour.from_now.change(usec: 0)
      response = instance_double(
        Faraday::Response,
        headers: {
          "x-ratelimit-remaining" => "3",
          "x-ratelimit-reset" => reset_at.to_i.to_s,
          "retry-after" => "12"
        }
      )

      limit = described_class.from_response(response)

      expect(limit.remaining).to eq(3)
      expect(limit.reset_at).to eq(reset_at)
      expect(limit.retry_after).to eq(12)
    end
  end

  describe "#should_wait?" do
    it "waits when remaining is at or below the threshold" do
      limit = described_class.new(remaining: 2, reset_at: 10.minutes.from_now)
      expect(limit.should_wait?).to be(true)
    end

    it "does not wait when remaining is healthy" do
      limit = described_class.new(remaining: 40, reset_at: 10.minutes.from_now)
      expect(limit.should_wait?).to be(false)
    end

    it "waits when Retry-After is present" do
      limit = described_class.new(remaining: 40, retry_after: 30)
      expect(limit.should_wait?).to be(true)
    end
  end

  describe "#seconds_until_reset" do
    it "prefers retry-after when present" do
      limit = described_class.new(remaining: 0, reset_at: 10.minutes.from_now, retry_after: 15)
      expect(limit.seconds_until_reset).to eq(15)
    end

    it "computes seconds until reset timestamp" do
      freeze_time = Time.zone.parse("2026-07-22 12:00:00")
      travel_to(freeze_time) do
        limit = described_class.new(remaining: 0, reset_at: freeze_time + 90.seconds)
        expect(limit.seconds_until_reset).to eq(90)
      end
    end
  end
end
