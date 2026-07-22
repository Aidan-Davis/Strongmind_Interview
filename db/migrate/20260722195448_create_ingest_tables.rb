# frozen_string_literal: true

class CreateIngestTables < ActiveRecord::Migration[8.0]
  def change
    create_table :actors do |t|
      t.bigint :github_id, null: false
      t.string :login, null: false
      t.string :avatar_url
      t.string :avatar_object_key
      t.jsonb :profile_json, null: false, default: {}
      t.datetime :fetched_at

      t.timestamps
    end
    add_index :actors, :github_id, unique: true
    add_index :actors, :login

    create_table :repositories do |t|
      t.bigint :github_id, null: false
      t.string :full_name, null: false
      t.string :html_url
      t.jsonb :profile_json, null: false, default: {}
      t.datetime :fetched_at

      t.timestamps
    end
    add_index :repositories, :github_id, unique: true
    add_index :repositories, :full_name

    create_table :push_events do |t|
      t.string :github_event_id, null: false
      t.bigint :repository_id, null: false
      t.bigint :push_id
      t.string :ref
      t.string :head
      t.string :before
      t.jsonb :raw_payload, null: false, default: {}
      t.string :raw_object_key
      t.string :enrichment_status, null: false, default: "pending"
      t.references :actor, foreign_key: true, null: true
      t.references :repository_record, foreign_key: { to_table: :repositories }, null: true

      t.timestamps
    end
    add_index :push_events, :github_event_id, unique: true
    add_index :push_events, :repository_id
    add_index :push_events, :push_id
    add_index :push_events, :enrichment_status
  end
end
