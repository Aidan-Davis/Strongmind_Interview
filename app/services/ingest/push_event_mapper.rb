# frozen_string_literal: true

module Ingest
  # Maps a GitHub API event hash into PushEvent attributes.
  class PushEventMapper
    def self.call(event)
      new(event).call
    end

    def initialize(event)
      @event = event.is_a?(Hash) ? event.with_indifferent_access : {}
    end

    def call
      payload = (@event[:payload] || {}).with_indifferent_access
      repo = (@event[:repo] || {}).with_indifferent_access

      repository_id = repo[:id] || payload[:repository_id]
      raise ArgumentError, "missing repository id" if repository_id.blank?
      raise ArgumentError, "missing event id" if @event[:id].blank?

      {
        github_event_id: @event[:id].to_s,
        repository_id: repository_id.to_i,
        push_id: payload[:push_id],
        ref: payload[:ref],
        head: payload[:head],
        before: payload[:before],
        raw_payload: @event.to_hash
      }
    end
  end
end
