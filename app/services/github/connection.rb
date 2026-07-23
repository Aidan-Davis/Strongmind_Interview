# frozen_string_literal: true

require "faraday"

module Github
  # Shared Faraday connection for GitHub REST clients: common headers, API
  # version, JSON response parsing, and bounded timeouts in one place so the
  # events poller and the enrichment client can't drift apart.
  module Connection
    DEFAULT_USER_AGENT = "StrongmindInterview-GitHubIngest/1.0"

    # Bound every request so a hung GitHub socket can't stall the poll loop or
    # the single Sidekiq enrichment worker indefinitely.
    OPEN_TIMEOUT = Integer(ENV.fetch("GITHUB_HTTP_OPEN_TIMEOUT_SECONDS", "5"))
    READ_TIMEOUT = Integer(ENV.fetch("GITHUB_HTTP_TIMEOUT_SECONDS", "15"))

    module_function

    # +base_url+ is set for the events poller (relative paths) and left nil for
    # the enrichment client, which fetches absolute actor/repo URLs.
    def build(base_url: nil, user_agent: DEFAULT_USER_AGENT)
      Faraday.new(url: base_url) do |f|
        f.response :json, content_type: /\bjson$/
        f.options.open_timeout = OPEN_TIMEOUT
        f.options.timeout = READ_TIMEOUT
        f.adapter Faraday.default_adapter
        f.headers["Accept"] = "application/vnd.github+json"
        f.headers["User-Agent"] = user_agent
        f.headers["X-GitHub-Api-Version"] = "2022-11-28"
      end
    end
  end
end
