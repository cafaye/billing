class AddEntitlementsToPlans < ActiveRecord::Migration[8.1]
  def change
    # What the plan grants. An object rather than an array of strings so a limit
    # has somewhere to live, and `{}` rather than a NULL because the wire
    # contract promises an object and a null would be a second shape.
    add_column :plans, :entitlements, :jsonb, null: false, default: {}
  end
end
