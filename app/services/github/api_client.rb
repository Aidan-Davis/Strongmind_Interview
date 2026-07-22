# frozen_string_literal: true

require "faraday"

module Github
  # Generic GitHub REST GET client for absolute resource URLs (actor/repo enrichment).
  class ApiClient
    DEFAULT_USER_AGENT = "StrongmindInterview-GitHubIngest/1.0"

    class Error < StandardError; end
    class RateLimited < Error
      attr_reader :rate_limit

      def initialize(message, rate_limit:)
        super(message)
        @rate_limit = rate_limit
      end
    end

    Result = Struct.new(:body, :rate_limit, keyword_init: true)

    def initialize(user_agent: ENV.fetch("GITHUB_USER_AGENT", DEFAULT_USER_AGENT), connection: nil)
      @user_agent = user_agent
      @connection = connection || default_connection
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
        raise Error, "GitHub resource not found: #{url}"
      else
        raise Error, "GitHub GET #{url} failed with HTTP #{response.status}"
      end
    end

    private

    def default_connection
      Faraday.new do |f|
        f.request :json
        f.response :json, content_type: /\bjson$/
        f.adapter Faraday.default_adapter
        f.headers["Accept"] = "application/vnd.github+json"
        f.headers["User-Agent"] = @user_agent
        f.headers["X-GitHub-Api-Version"] = "2022-11-28"
      end
    end
  end
end
