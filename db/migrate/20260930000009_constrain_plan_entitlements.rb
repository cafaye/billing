class ConstrainPlanEntitlements < ActiveRecord::Migration[8.1]
  def change
    # The top-level shape of the entitlements object, in the database.
    #
    # The per-element rules — a feature is a non-blank string, a limit is a
    # non-negative whole number — are in `Plan`, because a CHECK constraint cannot
    # state them without becoming a wall of SQL that nobody can read. What it *can*
    # state cheaply is that the column is an object and that the two members are the
    # kinds of thing the wire shape promises, which is enough to stop a row written
    # around the model from being something no reader expected.
    add_check_constraint :plans, "jsonb_typeof(entitlements) = 'object'",
      name: "plans_entitlements_is_object"

    add_check_constraint :plans,
      "NOT (entitlements ? 'features') OR jsonb_typeof(entitlements -> 'features') = 'array'",
      name: "plans_entitlements_features_is_array"

    add_check_constraint :plans,
      "NOT (entitlements ? 'limits') OR jsonb_typeof(entitlements -> 'limits') = 'object'",
      name: "plans_entitlements_limits_is_object"
  end
end
