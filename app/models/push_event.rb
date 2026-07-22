# frozen_string_literal: true

class PushEvent < ApplicationRecord
  ENRICHMENT_STATUSES = %w[pending enriched failed].freeze

  belongs_to :actor, optional: true
  belongs_to :repository_record, class_name: "Repository", optional: true

  validates :github_event_id, presence: true, uniqueness: true
  validates :repository_id, presence: true
  validates :enrichment_status, inclusion: { in: ENRICHMENT_STATUSES }
  validates :raw_payload, presence: true

  scope :pending_enrichment, -> { where(enrichment_status: "pending") }
end
