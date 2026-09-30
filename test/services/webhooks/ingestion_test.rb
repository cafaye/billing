require "test_helper"

# Ingestion is the boundary between a verified processor event and this
# service's own events. Three things are asserted that only this layer can be
# held to:
#
#   * it runs at most once per processor event id, even under a replay;
#   * a failure is *recorded* and the caller still gets a success, because a
#     processor that retries a 5xx forever is worse than one that retries a
#     recorded, alertable failure;
#   * a type this build does not handle is stored and marked processed, so
#     "we ignored it" is a query and not a guess.
#
# The events it writes go through `OutboxEvent`, the one outbox this service
# has, so every emission here is a row the closed type list and core's envelope
# grammar have already agreed to.
class Webhooks::IngestionTest < ActiveSupport::TestCase
  INVOICE_PAID = "invoice.paid".freeze

  setup do
    travel_to(frozen_now)
  end

  # Ingestion takes the parsed body, the way the controller hands it over after
  # verification. A fixture is JSON on disk, so it is parsed here rather than
  # passed as a string — a String would quietly answer `"…json…"["type"]` with
  # the substring, and every failure below would be a mystery.
  #
  # `event_id` defaults to the id inside the payload, which is what the
  # controller does: the stored row is keyed on the processor's own id for the
  # event, never on one invented here. Tests that need a replay pass the same id
  # twice, and tests that need two distinct events pass two ids.
  #
  # The fixture name is a label; the event's own `type` is what the controller
  # reads out of the verified body, and it is what decides the handler. Passing
  # the fixture name as the type instead would test a type Stripe never sends.
  def ingest(fixture, payload: nil, event_id: nil, type: nil)
    body = payload || JSON.parse(stripe_fixture(fixture))
    Webhooks::Ingestion.new(
      processor: :stripe,
      event_id: event_id || body["id"],
      type: type || body["type"],
      payload: body
    ).call
  end

  test "a handled event is stored, processed, and emits one internal event" do
    record = ingest(INVOICE_PAID)

    assert_predicate record, :persisted?
    assert_predicate record.processed_at, :present?
    assert_nil record.error
    assert_equal "stripe", record.processor
    assert_equal "evt_1PZQaBcDeFgHiJkLmNoPqR4", record.stripe_event_id
    assert_equal 1, OutboxEvent.count
  end

  test "the stored payload is the body verbatim, with the processor's own keys" do
    record = ingest(INVOICE_PAID)

    assert_equal JSON.parse(stripe_fixture(INVOICE_PAID)), record.payload
  end

  test "the row is keyed on the processor's own event id, not one this service invented" do
    record = ingest(INVOICE_PAID)

    assert_equal JSON.parse(stripe_fixture(INVOICE_PAID)).fetch("id"), record.stripe_event_id
  end

  test "replaying the same event id processes once" do
    first = ingest(INVOICE_PAID)
    second = ingest(INVOICE_PAID)

    assert_equal first.id, second.id
    assert_equal 1, ProcessorWebhook.count
    assert_equal 1, OutboxEvent.count
  end

  test "replaying a processed event does not re-emit" do
    ingest(INVOICE_PAID)
    ingest(INVOICE_PAID)

    assert_equal 1, OutboxEvent.where(event_type: "billing.payment.succeeded").count
  end

  # The replay that matters for money: a processor that redelivers an event
  # twenty minutes later must not produce a second billing.payment.succeeded with
  # a second envelope id, because a consumer that dedupes on that id would treat
  # it as new information.
  test "a late redelivery of the same event id emits no second event" do
    ingest(INVOICE_PAID)
    travel_to 20.minutes.from_now do
      ingest(INVOICE_PAID)
    end

    assert_equal 1, OutboxEvent.count
  end

  test "two different event ids of the same type are two events" do
    ingest(INVOICE_PAID, event_id: "evt_a")
    ingest(INVOICE_PAID, event_id: "evt_b")

    assert_equal 2, ProcessorWebhook.count
    assert_equal 2, OutboxEvent.count
  end

  test "an event with no handler is stored and marked processed as ignored" do
    record = ingest("charge.succeeded")

    assert_predicate record, :persisted?
    assert_predicate record.processed_at, :present?
    assert_equal "ignored:unhandled_event_type", record.error
    assert_equal 0, OutboxEvent.count
  end

  test "a deliberately ignored type records the reason it was ignored" do
    record = ingest("ping")

    assert_predicate record.processed_at, :present?
    assert_equal "ignored:connectivity_check", record.error
    assert_equal 0, OutboxEvent.count
  end

  test "ignoring is not a retry: the second ping is not processed again" do
    ingest("ping")
    ingest("ping")

    assert_equal 1, ProcessorWebhook.count
  end

  test "a handler that raises records the failure instead of propagating it" do
    exploding = Class.new do
      def self.call(*) = raise(ArgumentError, "deliberate test failure")
    end

    with_handler(INVOICE_PAID, exploding) do
      record = ingest(INVOICE_PAID)

      assert_predicate record.processed_at, :present?
      assert_equal "failed:ArgumentError: deliberate test failure", record.error
      assert_equal 0, OutboxEvent.count
    end
  end

  test "a failure is not retried as new work" do
    exploding = Class.new do
      def self.call(*) = raise(ArgumentError, "deliberate test failure")
    end

    with_handler(INVOICE_PAID, exploding) do
      ingest(INVOICE_PAID)
      ingest(INVOICE_PAID)
    end

    assert_equal 1, ProcessorWebhook.count
  end

  test "a rejected payload shape is recorded as a failure, not a 500" do
    record = ingest(INVOICE_PAID, payload: { "id" => "evt_1", "type" => "invoice.paid" })

    assert_predicate record.processed_at, :present?
    assert record.error.start_with?("failed:"), "expected a recorded failure, got: #{record.error.inspect}"
    assert_equal 0, OutboxEvent.count
  end

  test "a failure records the processor event id so the failing row is findable" do
    exploding = Class.new do
      def self.call(*) = raise(ArgumentError, "deliberate test failure")
    end

    record = with_handler_result(INVOICE_PAID, exploding) do
      ingest(INVOICE_PAID, event_id: "evt_findable")
    end

    found = ProcessorWebhook.find_by(stripe_event_id: "evt_findable")

    assert_equal record.id, found.id
    assert_predicate found.error, :present?
  end

  # The event and the receipt of it are one commit, not two. If the marking
  # happened after the emission committed, a marking that could not be written —
  # or a process that died — would leave an event already in the outbox with a row
  # that still says unfinished. The next delivery would then run the handler again
  # and emit a *second* `billing.payment.succeeded` with a *second* envelope id for
  # one charge, which is precisely the duplicate this table exists to prevent.
  #
  # A `before_update` that raises is the closest reachable thing to a process
  # dying during the marking: the write fails for a reason the row has no control
  # over, from inside the transaction the marking runs in.
  test "a marking that cannot be written leaves no event behind it" do
    with_refused_marking do
      assert_raises(ActiveRecord::StatementInvalid) { ingest(INVOICE_PAID) }
    end

    assert_equal 0, OutboxEvent.count
  end

  test "a marking that cannot be written leaves the row visibly unfinished" do
    with_refused_marking do
      assert_raises(ActiveRecord::StatementInvalid) { ingest(INVOICE_PAID) }
    end

    stored = ProcessorWebhook.sole

    assert_nil stored.processed_at
    assert_nil stored.error
  end

  # The other half: an unfinished row is picked up again rather than trusted, and
  # the second delivery emits exactly one event. This is the state a process
  # death leaves behind, and it is the one a naive implementation gets wrong.
  test "a redelivery of an event whose marking never landed is processed again" do
    with_refused_marking do
      assert_raises(ActiveRecord::StatementInvalid) { ingest(INVOICE_PAID) }
    end

    record = ingest(INVOICE_PAID)

    assert_equal 1, ProcessorWebhook.count
    assert_predicate record.processed_at, :present?
    assert_equal 1, OutboxEvent.count
    assert_equal "billing.payment.succeeded", OutboxEvent.sole.event_type
  end

  test "a subscription-mode checkout session is recorded as ignored, not as a failure" do
    record = ingest("checkout.session.completed")

    assert_predicate record.processed_at, :present?
    assert_equal "ignored:subscription_mode_is_restated_by_the_subscription_lifecycle", record.error
    assert_equal 0, OutboxEvent.count
  end

  test "a subscription-mode checkout session is not retried as new work" do
    ingest("checkout.session.completed")
    ingest("checkout.session.completed")

    assert_equal 1, ProcessorWebhook.count
  end

  test "a subscription signup states one fact once, not once per delivery channel" do
    create_stripe_customer
    create_stripe_plan

    ingest("checkout.session.completed")
    ingest("customer.subscription.created")

    assert_equal [ "billing.subscription.started" ],
      OutboxEvent.where(event_type: "billing.subscription.started").pluck(:event_type)
  end

  # The handler is now called with the payload *and* the time the change happened,
  # because a handler that writes domain state has to put that same instant in the
  # event's `time` and in its payload — core's schema requires the two to be equal.
  # Asserted here so a change to that arity is a failing test rather than an
  # ArgumentError parked on somebody's webhook row.
  test "a handler is given the payload and the time the change happened" do
    seen = []
    handler = ->(payload, event_time) do
      seen << [ payload.fetch("id"), event_time ]
      Webhooks::Emission.new(event_type: "billing.payment.succeeded", subject: "cus_1", data: {})
    end

    with_handler(INVOICE_PAID, handler) { ingest(INVOICE_PAID) }

    # The fixture's own `created`, not the moment the suite received it — which is
    # the whole point of handing the time to the handler.
    created = JSON.parse(stripe_fixture(INVOICE_PAID)).fetch("created")
    assert_equal [ [ "evt_1PZQaBcDeFgHiJkLmNoPqR4", Time.at(created).utc ] ], seen
  end

  # The subject is the entity the event is about, per core's envelope. There is no
  # subscriptions table in this build, so the only stable identifier we hold is a
  # Stripe one: a payment event is correlated on the Stripe subscription when the
  # payload carries one and on the customer otherwise. Recorded as a decision in
  # cafaye.yml; flipping it is one line in the normalizer.
  test "the subject is the processor's subscription id when the payload has one" do
    ingest(INVOICE_PAID)

    assert_equal "sub_1PZQaBcDeFgHiJkLmNoPqR1", OutboxEvent.sole.subject
  end

  test "the subject falls back to the customer id when there is no subscription" do
    ingest("checkout.session.completed.payment")

    assert_equal "cus_R1pQKz9xLp2mN4vB6yH8jL0", OutboxEvent.sole.subject
  end

  # The state change's own time, not the arrival time. A row that sat unpublished
  # for an hour must still report when the change happened, and an out-of-order
  # delivery is only detectable by a consumer if this is not the time it arrived.
  test "ingestion stamps the event's own time, not the time it was received" do
    travel_to 3.days.from_now do
      ingest(INVOICE_PAID)
    end

    assert_equal Time.utc(2026, 10, 7, 4, 0, 0), OutboxEvent.sole.time
  end

  test "an event with no processor timestamp falls back to the time it was received" do
    payload = JSON.parse(stripe_fixture(INVOICE_PAID))
    payload.delete("created")

    ingest(INVOICE_PAID, payload: payload)

    assert_equal frozen_now, OutboxEvent.sole.time
  end

  # Whatever leaves here has to be something the outbox will accept, or the
  # delivery is parked as a failure and Stripe is told 200 that nothing happened.
  # A mapping to a type the closed list does not hold is the quiet version of
  # that outage.
  test "a mapping to an event type the outbox does not list parks the row" do
    unlisted = Webhooks::Emission.new(event_type: "billing.payment.on_settled", subject: "pi_1", data: {})

    with_handler(INVOICE_PAID, ->(_payload, _event_time) { unlisted }) do
      record = ingest(INVOICE_PAID)

      assert record.error.start_with?("failed:ActiveRecord::RecordInvalid:"),
        "expected a parked row, got: #{record.error.inspect}"
      assert_predicate record.processed_at, :present?
      assert_equal 0, OutboxEvent.count
    end
  end

  test "a processor this service does not speak is refused at the edge" do
    assert_raises(ArgumentError) do
      Webhooks::Ingestion.new(processor: :adyen, event_id: "evt_1", type: "ping", payload: {}).call
    end
  end

  test "an event with no type is refused at the edge" do
    assert_raises(ArgumentError) do
      Webhooks::Ingestion.new(processor: :stripe, event_id: "evt_1", type: nil, payload: {}).call
    end
  end

  test "an event with no processor event id is refused at the edge" do
    assert_raises(ArgumentError) do
      Webhooks::Ingestion.new(processor: :stripe, event_id: nil, type: "ping", payload: {}).call
    end
  end

  private
    # The marking is the last thing that happens to a stored event, and a
    # `before_update` that raises is the closest reachable thing to a process
    # dying during it: the update fails for a reason the row has no control over,
    # from inside the transaction the marking runs in. If the event and the
    # marking are one commit, that failure takes the event with it.
    #
    # The filter is a named constant rather than a lambda written inline, because
    # `skip_callback` removes a proc by object identity and a block written twice
    # is two objects. It is removed in an `ensure` because this is a class-level
    # callback and the suite runs in one process.
    REFUSE_TO_MARK = ->(_record) { raise ActiveRecord::StatementInvalid, "connection lost while writing" }

    def with_refused_marking
      ProcessorWebhook.set_callback(:update, :before, REFUSE_TO_MARK)
      yield
    ensure
      ProcessorWebhook.skip_callback(:update, :before, REFUSE_TO_MARK)
    end

    # Replaces one type's handler so the failure path can be exercised without a
    # fixture that is genuinely broken. minitest 6 dropped `Object#stub`, so this
    # uses the stub registry ActiveSupport already ships.
    def with_handler(type, handler)
      real = Webhooks::StripeEvents.method(:handler_for)
      simple_stubs.stub_object(Webhooks::StripeEvents, :handler_for) do |given|
        given == type ? handler : real.call(given)
      end
      yield
    ensure
      simple_stubs.unstub_all!
    end

    # `with_handler` yields, and a stubbed call can return whatever the handler
    # returns, so this keeps the value from inside the block reachable outside it.
    def with_handler_result(type, handler)
      result = nil
      with_handler(type, handler) { result = yield }
      result
    end
end
