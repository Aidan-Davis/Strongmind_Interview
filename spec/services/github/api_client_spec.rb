# frozen_string_literal: true

RSpec.describe Github::ApiClient do
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:connection) do
    Faraday.new do |f|
      f.response :json, content_type: /\bjson$/
      f.adapter :test, stubs
    end
  end
  let(:client) { described_class.new(connection: connection) }
  let(:url) { "https://api.github.com/users/octocat" }

  after { stubs.verify_stubbed_calls }

  it "returns the parsed body and rate limit on 200" do
    stubs.get(url) do
      [
        200,
        { "Content-Type" => "application/json", "x-ratelimit-remaining" => "42" },
        { "id" => 1, "login" => "octocat" }.to_json
      ]
    end

    result = client.fetch_json(url)

    expect(result.body).to include("id" => 1, "login" => "octocat")
    expect(result.rate_limit.remaining).to eq(42)
  end

  it "raises RateLimited on 403" do
    stubs.get(url) do
      [
        403,
        { "Content-Type" => "application/json", "x-ratelimit-remaining" => "0", "x-ratelimit-reset" => 1.hour.from_now.to_i.to_s },
        { "message" => "rate limited" }.to_json
      ]
    end

    expect { client.fetch_json(url) }.to raise_error(Github::ApiClient::RateLimited)
  end

  it "raises the non-retryable NotFound on 404 for deleted actors/repos" do
    stubs.get(url) do
      [ 404, { "Content-Type" => "application/json" }, { "message" => "Not Found" }.to_json ]
    end

    expect { client.fetch_json(url) }.to raise_error(Github::ApiClient::NotFound)
  end

  it "requires a url" do
    expect { client.fetch_json(nil) }.to raise_error(ArgumentError)
  end
end
