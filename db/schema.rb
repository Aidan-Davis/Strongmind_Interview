# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_07_22_195448) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "actors", force: :cascade do |t|
    t.bigint "github_id", null: false
    t.string "login", null: false
    t.string "avatar_url"
    t.string "avatar_object_key"
    t.jsonb "profile_json", default: {}, null: false
    t.datetime "fetched_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["github_id"], name: "index_actors_on_github_id", unique: true
    t.index ["login"], name: "index_actors_on_login"
  end

  create_table "push_events", force: :cascade do |t|
    t.string "github_event_id", null: false
    t.bigint "repository_id", null: false
    t.bigint "push_id"
    t.string "ref"
    t.string "head"
    t.string "before"
    t.jsonb "raw_payload", default: {}, null: false
    t.string "raw_object_key"
    t.string "enrichment_status", default: "pending", null: false
    t.bigint "actor_id"
    t.bigint "repository_record_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_push_events_on_actor_id"
    t.index ["enrichment_status"], name: "index_push_events_on_enrichment_status"
    t.index ["github_event_id"], name: "index_push_events_on_github_event_id", unique: true
    t.index ["push_id"], name: "index_push_events_on_push_id"
    t.index ["repository_id"], name: "index_push_events_on_repository_id"
    t.index ["repository_record_id"], name: "index_push_events_on_repository_record_id"
  end

  create_table "repositories", force: :cascade do |t|
    t.bigint "github_id", null: false
    t.string "full_name", null: false
    t.string "html_url"
    t.jsonb "profile_json", default: {}, null: false
    t.datetime "fetched_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["full_name"], name: "index_repositories_on_full_name"
    t.index ["github_id"], name: "index_repositories_on_github_id", unique: true
  end

  add_foreign_key "push_events", "actors"
  add_foreign_key "push_events", "repositories", column: "repository_record_id"
end
