# frozen_string_literal: true

module Github
  # Generic GitHub REST GET client for absolute resource URLs (actor/repo enrichment).
  class ApiClient
    class Error < StandardError; end

    # A missing actor/repo (deleted account or repository) will never succeed on
    # retry, so it's raised as a distinct, non-retryable error.
    class NotFound < Error; end

    class RateLimited < Error
      attr_reader :rate_limit

      def initialize(message, rate_limit:)
        super(message)
        @rate_limit = rate_limit
      end
    end

    Result = Struct.new(:body, :rate_limit, keyword_init: true)

    def initialize(user_agent: ENV.fetch("GITHUB_USER_AGENT", Connection::DEFAULT_USER_AGENT), connection: nil)
      @connection = connection || Connection.build(user_agent: user_agent)
    end

    def fetch_json(url)
      raise ArgumentError, "url is required" if url.blank?

      response = @connection.get(url)
      rate_limit = RateLimit.from_response(response)

      case response.status
      when 200
        Result.new(body: response.body, rate_limit: rate_limit)
      when 403, 429
        raise RateLimited.new(
          "GitHub rate limited (HTTP #{response.status}) for #{url}",
          rate_limit: rate_limit
        )
      when 404
        raise NotFound, "GitHub resource not found: #{url}"
      else
        raise Error, "GitHub GET #{url} failed with HTTP #{response.status}"
      end
    end
  end
end
