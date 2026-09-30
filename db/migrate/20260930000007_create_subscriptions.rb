class CreateSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :subscriptions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # The account being billed: identity's uuid, with no foreign key and no
      # association, for the same reason `customers.owner_id` has none — the
      # class it would associate to lives in another service. It is frozen here
      # at creation from the customer's owner, which is itself a uuid that
      # cannot be reassigned (moving a customer is a delete and a create).
      t.uuid :account_id, null: false

      t.references :customer, type: :uuid, null: false, foreign_key: true
      t.references :plan, type: :uuid, null: false, foreign_key: true

      # The processor's own id. UNIQUE, and that index is the resolution
      # mechanism: every event about a subscription is looked up by it, so two
      # rows for one Stripe subscription would be two answers to one question.
      t.string :processor_subscription_id, null: false

      t.string :status, null: false

      t.timestamptz :current_period_start
      t.timestamptz :current_period_end
      t.boolean :cancel_at_period_end, null: false, default: false
      t.timestamptz :canceled_at

      # The processor's own `created` for the last event applied to this row.
      # Not a domain fact: it is the clock this service uses to tell a delivery
      # that arrived late from one that arrived now, because Stripe does not
      # promise ordering.
      t.timestamptz :last_processor_event_at

      t.timestamps
    end

    add_index :subscriptions, :processor_subscription_id, unique: true

    # One live subscription per (account, plan). Only live rows: a canceled
    # subscription is history, and a customer who cancels and comes back must be
    # able to subscribe to the same plan again. `status <> 'canceled'` is the
    # whole rule — `canceled` is the only terminal status this service has.
    add_index :subscriptions, %i[account_id plan_id],
      unique: true,
      where: "\"status\" <> 'canceled'",
      name: "subscriptions_live_account_plan_idx"

    # The statuses, inline rather than read from the model, so this migration
    # still means what it meant the day it ran.
    add_check_constraint :subscriptions,
      "\"status\"::text = ANY (ARRAY['trialing'::text, 'active'::text, 'past_due'::text, 'canceled'::text, 'unpaid'::text])",
      name: "subscriptions_status_known"
  end
end
