# frozen_string_literal: true

class Actor < ApplicationRecord
  has_many :push_events, dependent: :nullify

  validates :github_id, presence: true, uniqueness: true
  validates :login, presence: true

  def cache_fresh?(ttl: 24.hours)
    fetched_at.present? && fetched_at > ttl.ago
  end
end
