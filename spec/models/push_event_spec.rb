# frozen_string_literal: true

RSpec.describe PushEvent, type: :model do
  it "enforces unique github_event_id" do
    PushEvent.create!(
      github_event_id: "unique-1",
      repository_id: 1,
      raw_payload: { "id" => "unique-1" }
    )

    dup = PushEvent.new(
      github_event_id: "unique-1",
      repository_id: 2,
      raw_payload: { "id" => "unique-1" }
    )

    expect(dup).not_to be_valid
    expect(dup.errors[:github_event_id]).to be_present
  end
end
