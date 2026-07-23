# frozen_string_literal: true

module Github
  class EventsClient
    BASE_URL = "https://api.github.com"

    class Error < StandardError; end
    class RateLimited < Error
      attr_reader :rate_limit

      def initialize(message, rate_limit:)
        super(message)
        @rate_limit = rate_limit
      end
    end

    Result = Struct.new(:events, :etag, :rate_limit, :not_modified, keyword_init: true)

    def initialize(user_agent: ENV.fetch("GITHUB_USER_AGENT", Connection::DEFAULT_USER_AGENT), connection: nil)
      @connection = connection || Connection.build(base_url: BASE_URL, user_agent: user_agent)
    end

    # Fetches public events. Pass +etag+ for conditional requests (304 => not_modified).
    def fetch_events(etag: nil)
      headers = {}
      headers["If-None-Match"] = etag if etag.present?

      response = @connection.get("/events", nil, headers)
      rate_limit = RateLimit.from_response(response)

      case response.status
      when 304
        Result.new(events: [], etag: etag, rate_limit: rate_limit, not_modified: true)
      when 200
        body = response.body
        events = body.is_a?(Array) ? body : []
        Result.new(
          events: events,
          etag: response.headers["etag"],
          rate_limit: rate_limit,
          not_modified: false
        )
      when 403, 429
        raise RateLimited.new(
          "GitHub rate limited (HTTP #{response.status})",
          rate_limit: rate_limit
        )
      else
        raise Error, "GitHub /events failed with HTTP #{response.status}: #{response.body.to_s.truncate(200)}"
      end
    end
  end
end
