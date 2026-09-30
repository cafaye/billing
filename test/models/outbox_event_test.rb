require "test_helper"

class OutboxEventTest < ActiveSupport::TestCase
  OWNER_ID = "11111111-1111-4111-8111-111111111111"

  setup do
    travel_to(frozen_now)
  end

  # --- the envelope -----------------------------------------------------------

  test "a created customer emits billing.customer.created" do
    customer = create_customer

    event = only_event

    assert_equal "billing.customer.created", event.event_type
    assert_equal "billing", event.source
    assert_equal customer.id, event.subject
  end

  test "a created plan emits billing.plan.created" do
    create_plan

    assert_equal "billing.plan.created", only_event.event_type
  end

  test "an updated plan emits billing.plan.updated" do
    plan = create_plan
    last_event
    travel 1.second

    plan.update!(name: "Pro monthly, annually")

    assert_equal 2, OutboxEvent.count
    assert_equal "billing.plan.updated", last_event.event_type
    assert_equal plan.id, last_event.subject
  end

  test "an update that changes nothing emits nothing, because nothing happened" do
    plan = create_plan
    last_event

    plan.update!(name: plan.name)

    assert_equal 1, OutboxEvent.count
  end

  test "a created plan does not also emit an update" do
    create_plan

    assert_equal [ "billing.plan.created" ], OutboxEvent.order(:created_at).pluck(:event_type)
  end

  test "the envelope is the shape core's schema describes" do
    customer = create_customer

    assert_equal(
      {
        "specversion" => "1.0",
        "id" => only_event.id,
        "type" => "billing.customer.created",
        "source" => "billing",
        "subject" => customer.id,
        "time" => frozen_now.iso8601,
        "data" => customer.as_json
      },
      only_event.to_envelope
    )
  end

  test "the event id is a uuid, because consumers deduplicate on it" do
    create_customer
    create_customer(owner_id: "22222222-2222-4222-8222-222222222222")

    assert_match Identifiers::UUID, only_event.id
    assert_equal 2, OutboxEvent.pluck(:id).uniq.size
  end

  test "the event time is the state change, not the transport" do
    create_customer

    assert_equal frozen_now, only_event.time
  end

  test "the payload carries money as minor units" do
    create_plan

    assert_equal({ "amount_minor" => 1900, "currency" => "USD" }, only_event.data.fetch("price"))
  end

  # --- the transaction --------------------------------------------------------

  test "the event is written inside the record's transaction, so a rollback takes it too" do
    Customer.transaction do
      create_customer

      # Written already, before anything has committed. An after_commit hook
      # would leave this at zero.
      assert_equal 1, OutboxEvent.count

      raise ActiveRecord::Rollback
    end

    assert_equal 0, Customer.count
    assert_equal 0, OutboxEvent.count
  end

  test "a rejected record emits nothing" do
    assert_no_difference("OutboxEvent.count") do
      assert_not Customer.new(owner_type: "User", owner_id: nil, processor: "stripe").save
    end
  end

  # --- the row's own rules ----------------------------------------------------

  test "an event type is the three-segment form this service publishes" do
    event = build_event(event_type: "customer.created")

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :event_type
  end

  test "an event type is one of the types this service publishes" do
    event = build_event(event_type: "billing.invoice.created")

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :event_type
  end

  test "an event subject is the entity id and is required" do
    event = build_event(subject: nil)

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :subject
  end

  test "an event subject cannot smuggle transport metadata into the envelope" do
    event = build_event(subject: "a b c")

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :subject
  end

  test "an event payload is an object" do
    event = build_event(data: "created")

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :data
  end

  # --- the times -------------------------------------------------------------

  # A webhook's event describes a state change that already happened somewhere
  # else, seconds or days ago. Stamping it with the moment this service wrote the
  # row would make out-of-order delivery undetectable, because every event would
  # appear to have happened in the order it arrived.
  test "the time can be the state change's own, not the moment of the write" do
    event = OutboxEvent.publish!(
      type: "billing.payment.succeeded",
      subject: "pi_1",
      data: {},
      time: Time.utc(2026, 10, 7, 4, 0, 0)
    )

    assert_equal Time.utc(2026, 10, 7, 4, 0, 0), event.time
  end

  test "the time falls back to now for a change this service just made" do
    event = OutboxEvent.publish!(type: "billing.payment.failed", subject: "pi_1", data: {})

    assert_equal frozen_now, event.time
  end

  test "a caller that passes no time and one that passes an explicit time differ" do
    travel 1.hour do
      assert_not_equal(
        OutboxEvent.publish!(type: "billing.payment.failed", subject: "pi_1", data: {}).time,
        OutboxEvent.publish!(type: "billing.payment.failed", subject: "pi_2", data: {}, time: frozen_now).time
      )
    end
  end

  # --- the closed list -------------------------------------------------------

  # The list is the service's published contract: the models emit three of these
  # and the webhook mapping emits the other five, and `test/contract` asserts the
  # manifest agrees. A type that fell out of it would be refused at the write,
  # from inside a webhook, as a parked row answered 200.
  DECLARED_TYPES = %w[
    billing.customer.created
    billing.payment.failed
    billing.payment.succeeded
    billing.plan.created
    billing.plan.updated
    billing.subscription.canceled
    billing.subscription.started
    billing.subscription.updated
  ].freeze

  test "the declared types are the three-segment types this build emits" do
    assert_equal DECLARED_TYPES.sort, OutboxEvent::TYPES.sort
  end

  DECLARED_TYPES.each do |type|
    test "#{type} is a type this service publishes" do
      event = build_event(event_type: type)

      assert event.valid?, event.errors.full_messages.join("; ")
    end
  end

  test "a type from the catalog this build does not publish is still refused" do
    event = build_event(event_type: "billing.payment.refunded")

    assert_not event.valid?
    assert_includes event.errors.attribute_names, :event_type
  end

  private
    def create_customer(overrides = {})
      Customer.create!({ owner_type: "User", owner_id: OWNER_ID, processor: "stripe" }.merge(overrides))
    end

    def create_plan(overrides = {})
      Plan.create!({
        name: "Pro monthly",
        slug: "pro-monthly",
        price: Money.new(1900, "USD"),
        interval: "month"
      }.merge(overrides))
    end

    def only_event
      OutboxEvent.last
    end

    def last_event
      OutboxEvent.order(:created_at, :id).last
    end

    # A row that is valid apart from whatever a test overrides. `source` and
    # `time` are set because the tests below are about one attribute at a time,
    # and a row that is invalid for three reasons cannot say which one.
    def build_event(overrides = {})
      OutboxEvent.new({
        event_type: "billing.customer.created",
        source: OutboxEvent::SERVICE,
        subject: OWNER_ID,
        time: frozen_now,
        data: {}
      }.merge(overrides))
    end
end
