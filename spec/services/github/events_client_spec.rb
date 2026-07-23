# frozen_string_literal: true

RSpec.describe Github::EventsClient do
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:connection) do
    Faraday.new(url: "https://api.github.com") do |f|
      f.response :json, content_type: /\bjson$/
      f.adapter :test, stubs
    end
  end
  let(:client) { described_class.new(connection: connection) }

  after { stubs.verify_stubbed_calls }

  it "returns event payloads on 200" do
    stubs.get("/events") do
      [
        200,
        {
          "Content-Type" => "application/json",
          "etag" => "W/\"abc\"",
          "x-ratelimit-remaining" => "50"
        },
        [ { "id" => "1", "type" => "PushEvent" } ].to_json
      ]
    end

    result = client.fetch_events

    expect(result.not_modified).to be(false)
    expect(result.events.size).to eq(1)
    expect(result.etag).to eq("W/\"abc\"")
    expect(result.rate_limit.remaining).to eq(50)
  end

  it "returns not_modified on 304" do
    stubs.get("/events") do
      [ 304, { "x-ratelimit-remaining" => "50", "Content-Type" => "application/json" }, "null" ]
    end

    result = client.fetch_events(etag: "W/\"abc\"")

    expect(result.not_modified).to be(true)
    expect(result.events).to eq([])
  end

  it "raises RateLimited on 403" do
    stubs.get("/events") do
      [
        403,
        {
          "Content-Type" => "application/json",
          "x-ratelimit-remaining" => "0",
          "x-ratelimit-reset" => 1.hour.from_now.to_i.to_s
        },
        { "message" => "rate limited" }.to_json
      ]
    end

    expect { client.fetch_events }.to raise_error(Github::EventsClient::RateLimited)
  end
end
