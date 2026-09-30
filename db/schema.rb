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

ActiveRecord::Schema[8.1].define(version: 2026_09_30_000006) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "customers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "owner_type", null: false
    t.uuid "owner_id", null: false
    t.string "processor", null: false
    t.string "processor_customer_id"
    t.string "email"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id", "processor"], name: "index_customers_on_owner_type_and_owner_id_and_processor", unique: true
    t.check_constraint "processor::text = 'stripe'::text", name: "customers_processor_known"
  end

  create_table "idempotency_keys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "endpoint", null: false
    t.string "principal", null: false
    t.string "key", null: false
    t.string "request_digest", null: false
    t.integer "status", null: false
    t.text "response_body", null: false
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_idempotency_keys_on_created_at"
    t.index ["endpoint", "principal", "key"], name: "index_idempotency_keys_on_endpoint_and_principal_and_key", unique: true
  end

  create_table "outbox_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "event_type", null: false
    t.string "source", null: false
    t.string "subject", null: false
    t.timestamptz "time", null: false
    t.jsonb "data", null: false
    t.timestamptz "published_at"
    t.integer "attempts", default: 0, null: false
    t.timestamptz "created_at", null: false
    t.index ["created_at"], name: "outbox_events_unpublished_idx", where: "(published_at IS NULL)"
    t.index ["subject", "created_at"], name: "outbox_events_subject_created_at_idx"
  end

  create_table "plans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "processor_product_id"
    t.string "processor_price_id"
    t.integer "amount_cents", null: false
    t.string "currency", limit: 3, null: false
    t.string "interval", null: false
    t.integer "trial_days", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_plans_on_slug", unique: true
    t.check_constraint "\"interval\"::text = ANY (ARRAY['month'::character varying, 'year'::character varying, 'one_time'::character varying]::text[])", name: "plans_interval_known"
    t.check_constraint "amount_cents >= 0", name: "plans_amount_cents_not_negative"
    t.check_constraint "trial_days >= 0", name: "plans_trial_days_not_negative"
  end

  create_table "processor_webhooks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "processor", null: false
    t.string "stripe_event_id", null: false
    t.string "type", null: false
    t.jsonb "payload", default: {}, null: false
    t.timestamptz "processed_at"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["processed_at"], name: "processor_webhooks_unprocessed_idx", where: "(processed_at IS NULL)"
    t.index ["stripe_event_id"], name: "index_processor_webhooks_on_stripe_event_id", unique: true
    t.check_constraint "processor::text = 'stripe'::text", name: "processor_webhooks_processor_known"
  end
end
