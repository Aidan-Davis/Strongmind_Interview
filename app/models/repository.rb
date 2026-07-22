# frozen_string_literal: true

class Repository < ApplicationRecord
  has_many :push_events, foreign_key: :repository_record_id, inverse_of: :repository_record, dependent: :nullify

  validates :github_id, presence: true, uniqueness: true
  validates :full_name, presence: true

  def cache_fresh?(ttl: 24.hours)
    fetched_at.present? && fetched_at > ttl.ago
  end
end
