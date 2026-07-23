# frozen_string_literal: true

RSpec.describe "Health", type: :request do
  it "returns 200 from GET /up" do
    get "/up"

    expect(response).to have_http_status(:ok)
  end
end
