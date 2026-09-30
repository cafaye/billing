require "test_helper"

# Two deliveries of **one** Stripe event id, arriving at the same moment.
#
# ## The defect this file exists for
#
# `Webhooks::Ingestion#call` is a check followed by an act:
#
# ```ruby
# webhook = ProcessorWebhook.ingest(...)
# return webhook if webhook.handled?     # the read
# dispatch(webhook)                      # ... which writes billing.payment.succeeded
# ```
#
# The unique index on `processor_webhooks.stripe_event_id` makes the two threads
# agree about *which row* they are working on, and `AGENTS.md` says that index is
# the correctness mechanism. It is — and it is not enough, because agreement
# about the row is not agreement about the answer. `handled?` reads a column that
# neither thread has written yet: each is about to write it. Under READ COMMITTED
# neither sees the other's uncommitted work, both read `nil`, and both emit.
#
# The result is **two `billing.payment.succeeded` rows with two different envelope
# ids for one charge**. core defines the envelope `id` as the dedupe key, so a
# consumer that dedupes on it cannot tell the second from new information about
# somebody's money. This is the most expensive bug the packet found, and it is
# not visible to any single-threaded test — which is why the file exists.
#
# Note what the stale-delivery guard does *not* do here. It refuses a delivery
# that predates the row; two deliveries of one event id carry the *same*
# processor timestamp, so both are current, both pass it, and it has nothing to
# say. Ordering and at-most-once are different guarantees and neither substitutes
# for the other.
#
# ## Why this is deterministic, and not a race that happens to go our way
#
# There is no sleep, no retry and no loosened assertion anywhere in this file.
# The interleaving is **manufactured**: `ProcessorWebhook#handled?` is the mouth
# of the check-then-act window, and a two-party barrier holds both threads in it
# until both have arrived. Without that, "two threads, same event id" is a
# *probable* duplicate, and a test that asserts a probable outcome is a flake
# generator — it passes on a fast machine and fails on a loaded one, and the
# project's standing rule is that "it passed most of the time" is not a result.
#
# The barrier is on `handled?` and not on the outbox insert on purpose: the
# database is what arbitrates the write, and a test that also arbitrated it
# would be testing the test.
#
# ## Why this class is not transactional, and what that costs
#
# Two threads need two database connections, and a connection cannot see another
# connection's uncommitted work. A test wrapped in its own open transaction would
# therefore assert against an empty database while both deliveries wrote real
# committed rows into the worker's. So `use_transactional_tests` is off here and
# the two tables this path writes are cleared in `setup` **and** `teardown`.
# Nothing else in the suite does this, and that is worth saying out loud: this is
# the only class in the repository whose rows outlive its own test, which is why
# the teardown is unconditional and why it is keyed to this file's own event ids
# rather than to a blanket truncation.
#
# Turning it off has a second cost, and it is the one that would have made this
# file lie. Active Record's query cache is **on** in the test environment
# (`connection.query_cache_enabled` is true), it is cleared between tests but
# **not** within one, and every count in this file is issued on the main thread
# *after* the worker threads have committed. A `SELECT COUNT(*)` taken before
# the threads ran and repeated after them returns the first answer — measured,
# not assumed: with the cache live, `ProcessorWebhook.count` read `0` in a test
# whose raw SQL read one stored, finished row.
#
# A count that cannot see the rows it is counting is a tripwire wired to nothing,
# and this is the one file in the repository where a green count would mean
# nothing at all. So the barrier's block ends by dropping the cache on this
# thread before any assertion reads anything: `Thread` boundaries do not clear
# it, and the only honest moment to measure is after the last commit.
#
# ## What is asserted, and what deliberately is not
#
# Which thread wins is genuinely not determined, and the test does not pretend
# otherwise: it asserts the *outcome*, which the unique index makes
# order-independent. Where the per-thread detail matters — the reason the losing
# delivery records — it is read off each thread's **returned record** rather than
# off the stored row, because both threads hold the same row and the last writer
# to it wins. The stored row is asserted only on what is order-independent: that
# the delivery is finished and is not parked for a human.
class Webhooks::ConcurrentDeliveryTest < ActiveSupport::TestCase
  # The two deliveries are threads, and a thread cannot see this test's
  # uncommitted transaction. See the class comment; this is the only class in the
  # repository that turns it off.
  self.use_transactional_tests = false

  INVOICE_PAID = "invoice.paid".freeze
  DUPLICATE_REASON = "ignored:duplicate_delivery".freeze

  setup do
    travel_to(frozen_now)
    clear_written_tables
  end

  teardown do
    clear_written_tables
  end

  # --- the regression: one event id, one event -------------------------------

  # The assertion that is the whole point. Before the fix this reads `2`, and
  # the two rows have different envelope ids — which is the money bug, stated as
  # a count.
  test "two simultaneous deliveries of one event id emit one event" do
    deliver_twice_at_once

    assert_equal 1, outbox_rows,
      "one Stripe event id produced #{outbox_rows} outbox rows. Two rows are " \
      "two envelope ids, and core's envelope id is the dedupe key — a consumer " \
      "cannot tell the second from new information about the same charge."
  end

  test "the event that survives is the payment, and it names the processor event once" do
    deliver_twice_at_once

    event = OutboxEvent.sole
    assert_equal "billing.payment.succeeded", event.event_type
    assert_equal [ "evt_1PZQaBcDeFgHiJkLmNoPqR4" ],
      event.data.values_at("processor_event_id")
  end

  # The delivery is still accounted for. A refusal that left `processed_at` null
  # would be read by the next delivery as unfinished work and redone, and a
  # `failed:` note would park a row for a human over an event that is already
  # published and perfectly fine.
  test "the delivery is finished, and is not parked for a human" do
    deliver_twice_at_once

    row = ProcessorWebhook.sole
    assert_predicate row.processed_at, :present?,
      "processed_at is null, so the next delivery treats this as unfinished and redoes it"
    refute row.failed?,
      "a duplicate delivery is a decision, not a failure. Parked as failed:#{row.error}"
  end

  # The reason, read off what each thread *returned* rather than off the stored
  # row. Both threads hold the same `ProcessorWebhook` row and both write to it,
  # so the stored `error` is whichever committed last — genuinely not determined,
  # and asserting it would be asserting a coin toss. The returned records are
  # unambiguous: the winner cleared the error, the loser recorded why it emitted
  # nothing.
  test "the delivery that lost records why, so a human can query it" do
    records = deliver_twice_at_once
    errors = records.map(&:error)

    # Counted, not sorted: `sort` on an array holding `nil` raises
    # `comparison of String with nil failed`, which is the test dying of its own
    # bookkeeping rather than reporting the defect.
    assert_equal 1, errors.count(DUPLICATE_REASON),
      "exactly one delivery must record #{DUPLICATE_REASON.inspect}; got #{errors.inspect}"
    assert_equal 1, errors.count(nil),
      "exactly one delivery must have emitted and cleared the error; got #{errors.inspect}"
  end

  # Both requests finish, and neither raises. The ingestion layer's contract is
  # that a stored payload never raises: a 500 here would tell Stripe to
  # redeliver, and the redelivery would race again — which is the one thing that
  # is guaranteed to reproduce this bug.
  test "neither delivery raises, so the endpoint answers 200 twice" do
    records = deliver_twice_at_once

    assert_equal 2, records.size
    records.each { |record| assert_predicate record, :persisted? }
  end

  # The delivery row itself is the at-most-once record, and it must be *one* row
  # however many requests arrived. `ProcessorWebhook.ingest`'s own unique index
  # already guarantees this; the test is here because the fix adds a second index
  # on a second table and a duplicate row would be a different, quieter failure.
  test "two simultaneous deliveries of one event id are recorded once" do
    deliver_twice_at_once

    assert_equal 1, delivery_rows
  end

  # --- the control for the parking branch ------------------------------------
  #
  # `Ingestion#emit` has a `rescue ActiveRecord::RecordInvalid` that reads the
  # *error* rather than the exception class, so a uniqueness failure is recorded
  # as a duplicate and everything else is parked for a human. That branch is only
  # safe if it is narrow, and "narrow" is a claim about a predicate.
  #
  # **A validation failure that is not about uniqueness must still be parked.**
  # A delivery naming a plan this service does not sell fails validation for
  # `unknown_plan`, which is a `Subscriptions::Refused` the lifecycle raises — so
  # the honest control is a genuine, non-racy invalid record reaching the same
  # rescue. `ProcessorWebhook` is the simplest: `stripe_event_id` has a presence
  # validation, and a blank one is a programming error in the caller, not a
  # duplicate. If `uniqueness_race?` ever widened to "any `RecordInvalid`", this
  # would be recorded as `ignored:duplicate_delivery` and a bug in this service
  # would be filed as a race and answered 200.
  test "a validation failure that is not a uniqueness race is still parked for a human" do
    record = Customer.new(processor: "stripe", processor_customer_id: "cus_control")

    error = assert_raises(ActiveRecord::RecordInvalid) { record.save! }

    refute ingestion_says_uniqueness_race?(error),
      "a plain validation failure was read as the duplicate a constraint already " \
      "recorded. Widening this predicate files a bug in this service as a race and " \
      "answers the processor 200."
  end

  # The same claim from the other side, and the reason the control above can be
  # trusted: the predicate really does recognise a uniqueness failure, so the
  # `RecordInvalid` branch is not simply dead code. A duplicate customer is
  # refused by a uniqueness **validation** here and by a unique **index** in the
  # concurrent case — one fact, two ways, which is the whole reason the branch
  # exists.
  test "the predicate recognises a uniqueness failure as a duplicate" do
    # The **same owner**, because `Customer`'s rule is one customer per
    # `(owner_type, owner_id, processor)` and not one per processor customer id —
    # a different owner would be a different customer and would not be refused.
    owner = SecureRandom.uuid
    Customer.create!(owner_type: "User", owner_id: owner,
      processor: "stripe", processor_customer_id: "cus_dup_control")
    duplicate = Customer.new(owner_type: "User", owner_id: owner,
      processor: "stripe", processor_customer_id: "cus_dup_control")

    error = assert_raises(ActiveRecord::RecordInvalid) { ActiveRecord::Base.uncached { duplicate.save! } }

    assert ingestion_says_uniqueness_race?(error),
      "a real uniqueness failure was not recognised, so a losing delivery would be " \
      "parked as a failure for an event that is already published"
  end

  # --- the other duplicate route, closed by a different index ----------------

  # `billing.subscription.started` is published for a
  # `customer.subscription.created`, and **that payload carries no
  # `processor_event_id`** — the lifecycle's start payload is `core_payload` plus
  # `started_at`, and `lifecycle_test.rb` asserts the key's absence. So the new
  # outbox index cannot be what refuses this duplicate: the outbox insert is
  # never reached, because the second `INSERT` into `subscriptions` is refused
  # first, by `subscriptions.processor_subscription_id`.
  #
  # That is a claim about which constraint fires, and it was **measured rather
  # than argued**: with both of the `subscriptions` indexes dropped, the same two
  # deliveries produce `SUBS=2 STARTED=2` — two subscription rows and two
  # `billing.subscription.started` events. So the property genuinely rests on two
  # separate constraints, and the ingestion layer's rescue sits on the exception
  # class precisely so it covers both routes.
  test "two simultaneous creations of one subscription produce one subscription and one start" do
    body, = subscription_fixture_rows

    records = deliver_concurrently(body, event_id: "evt_1PZQaBcDeFgHiJkLmNoPqR5")

    assert_equal 1, subscription_rows,
      "#{subscription_rows} subscription rows for one processor subscription id. The " \
      "outbox index cannot catch this one: a start payload carries no processor_event_id."
    assert_equal 1, started_events,
      "billing.subscription.started was published twice; a consumer counting " \
      "signups would count every signup twice"
    refute records.any?(&:failed?),
      "the losing creation was parked as a failure: #{records.map(&:error).inspect}"
  end

  # The premise of the test above, asserted rather than assumed: the start payload
  # really does lack the key the outbox index is built on. If a future change gave
  # it one, this file's other half would start testing the outbox index here and
  # the `subscriptions` table's own constraints would quietly become untested.
  test "a start payload carries no processor_event_id, so the subscriptions table refuses the duplicate" do
    body, = subscription_fixture_rows

    # The id is merged into the body, as it is in production and as
    # `ingest_body` below does it. A delivery under an id its own payload does
    # not carry is a state Stripe never sends, and it is the pattern that let two
    # suites publish events claiming to be the same one.
    Webhooks::Ingestion.new(
      processor: :stripe, event_id: "evt_started_shape",
      type: body["type"], payload: body.merge("id" => "evt_started_shape")
    ).call

    start = OutboxEvent.find_by(event_type: "billing.subscription.started")
    refute start.data.key?("processor_event_id"),
      "if the start payload carried the key, this file's other half would be " \
      "testing the outbox index and the subscriptions index would be untested"
  end

  # --- the negative control, so the test above cannot pass for the wrong reason

  # **Two different event ids are two events**, and the index must not have
  # overreached into refusing them. This is the direction a constraint test that
  # only checks "it raised" never checks, and it is the direction that finds an
  # index written over the wrong expression — for instance over `subject`, where
  # a subscription's started and updated events share one and a correct
  # implementation would start refusing real deliveries.
  test "two simultaneous deliveries of two different event ids emit two events" do
    deliver_twice_at_once(event_ids: [ "evt_race_a", "evt_race_b" ])

    assert_equal 2, outbox_rows
    assert_equal %w[evt_race_a evt_race_b],
      ActiveRecord::Base.uncached {
        OutboxEvent.order(:created_at, :id).pluck(:data).map { |data| data.fetch("processor_event_id") }.sort
      }
  end

  # The two must be told apart, not merely counted: an index that refused
  # everything would also pass the count above if one delivery had raised and
  # been parked.
  test "two simultaneous deliveries of two different event ids are both handled" do
    records = deliver_twice_at_once(event_ids: [ "evt_race_a", "evt_race_b" ])

    # Asserted as "neither was recorded as a duplicate" rather than as an exact
    # list, so this fails for the right reason if the index overreaches and one
    # of two legitimate events is refused.
    refute_includes records.map(&:error), DUPLICATE_REASON,
      "two different event ids are two events; neither may be recorded as a duplicate"
    records.each { |record| assert_nil record.error, "a delivery that emitted carries no error" }
  end

  private
    # The predicate `Ingestion#emit` uses to tell a uniqueness race from a genuine
    # validation failure, asked of the real object.
    #
    # It is a private method, so it is reached with `send`. That is the price of
    # asserting a private decision rather than its consequence: the consequence is
    # only observable in a race, and a race that may not be scheduled is not a
    # test. The alternative — asserting only that duplicate deliveries are never
    # parked — passes just as well when the predicate is deleted entirely.
    def ingestion_says_uniqueness_race?(error)
      Webhooks::Ingestion.allocate.send(:uniqueness_race?, error)
    end

    # The counts, each read past the query cache.
    #
    # See the class comment: the cache is live in the test environment, it is
    # cleared between tests but not within one, and every count here is taken on
    # the main thread after the worker threads committed. `uncached` is per
    # relation and per call, which is what makes it safe to write the failure
    # message in terms of the same number the assertion used — a message that
    # re-counts through a cache would print `1` on the one run where the answer
    # was `2`, and this file exists to report exactly that run.
    def outbox_rows
      ActiveRecord::Base.uncached { OutboxEvent.count }
    end

    def delivery_rows
      ActiveRecord::Base.uncached { ProcessorWebhook.count }
    end

    def subscription_rows
      ActiveRecord::Base.uncached { Subscription.count }
    end

    def started_events
      ActiveRecord::Base.uncached { OutboxEvent.where(event_type: "billing.subscription.started").count }
    end

    # Runs two deliveries of the same event id at the same moment, and returns
    # each thread's own `ProcessorWebhook` record.
    #
    # `Thread#value` is what re-raises a thread's exception into this one: without
    # it a thread that died would take the test down with an unrelated error at
    # `join`, and the assertion below would never run. A thread that raises is a
    # failure here, which is the point — the ingestion layer must not raise for a
    # payload it has stored.
    def deliver_twice_at_once(event_ids: [ INVOICE_PAID_PAYLOAD_ID, INVOICE_PAID_PAYLOAD_ID ])
      body = JSON.parse(stripe_fixture(INVOICE_PAID))

      holding_the_gate_open(BothArrived.new) do
        records = event_ids.map { |event_id| Thread.new { ingest_body(body, event_id) } }.map(&:value)
        forget_what_was_counted_before_the_threads_ran
        records
      end
    end

    # The id inside the committed `invoice.paid` fixture, which is what the
    # controller uses: the stored row is keyed on the processor's own id and
    # never on one invented here.
    INVOICE_PAID_PAYLOAD_ID = "evt_1PZQaBcDeFgHiJkLmNoPqR4".freeze

    def ingest(event_id)
      ingest_body(JSON.parse(stripe_fixture(INVOICE_PAID)), event_id)
    end

    # The `customer.subscription.created` fixture plus the customer and plan it
    # resolves to, because the lifecycle refuses a delivery it cannot attach to a
    # customer and a plan (`unknown_customer`, `unknown_plan`).
    #
    # The processor ids are read out of the committed fixture rather than
    # invented, so a fixture edited without its tests failing is still caught
    # here. They **cannot** be made unique per call, and that is the reason the
    # teardown clears `customers` and `plans` too: the lifecycle resolves a
    # delivery by matching the payload's own ids, so a randomized id would
    # produce `unknown_customer` instead of a subscription. The repository's
    # uniqueness rules are what make the ids fixed, and the teardown is what lets
    # two tests in one class use the same fixture twice.
    def subscription_fixture_rows
      body = JSON.parse(stripe_fixture("customer.subscription.created"))
      object = body.dig("data", "object")

      create_stripe_customer(processor_customer_id: object["customer"])
      create_stripe_plan(processor_price_id: object.dig("items", "data", 0, "price", "id"))

      [ body, object ]
    end

    # One delivery, and the barrier's plumbing shared with the paired one. Split
    # out so the subscription case above can hand in a `customer.subscription.created`
    # body with a customer and a plan already created for it.
    def ingest_body(body, event_id)
      body = body.merge("id" => event_id, "type" => body["type"])
      Webhooks::Ingestion.new(
        processor: :stripe, event_id: event_id, type: body["type"], payload: body
      ).call
    end

    # Two deliveries of one body at the same moment, and each thread's record.
    def deliver_concurrently(body, event_id:)
      barrier = BothArrived.new

      holding_the_gate_open(barrier) do
        records = 2.times.map { Thread.new { ingest_body(body, event_id) } }.map(&:value)
        forget_what_was_counted_before_the_threads_ran
        records
      end
    end

    # Drops this thread's query cache once the deliveries have committed.
    #
    # The barrier's threads have their own connections and their own caches;
    # nothing a worker thread did invalidates anything this thread read earlier.
    # Clearing here rather than in each assertion is what makes "the count after
    # the race" a single, unambiguous moment instead of one that depends on which
    # helper happened to be called first.
    def forget_what_was_counted_before_the_threads_ran
      ActiveRecord::Base.connection.clear_query_cache
    end

    # Replaces `ProcessorWebhook#handled?` for the duration of the block with a
    # version that parks the calling thread at `barrier` and then answers the
    # real question.
    #
    # `alias_method` rather than `prepend` because Ruby cannot un-prepend a
    # module, and a file-scope `prepend` in a test would change the behaviour of
    # every other test in the suite for the rest of the run. This restores the
    # original in `ensure`, so a failing assertion cannot leak the gate into the
    # next test — and the repository's `simple_stubs` cannot do this, because it
    # aliases onto a *singleton* and an instance method has to be replaced on the
    # class.
    def holding_the_gate_open(barrier)
      ProcessorWebhook.class_eval do
        alias_method :ungated_handled?, :handled?
        define_method(:handled?) do
          barrier.wait_for_the_other
          ungated_handled?
        end
      end

      yield
    ensure
      ProcessorWebhook.class_eval do
        alias_method :handled?, :ungated_handled?
        remove_method :ungated_handled?
      end
    end

    # Every table the paths under test write, cleared in `setup` **and**
    # `teardown`, children before parents so the foreign keys stay satisfied.
    #
    # `customers` and `plans` are here because the subscription case creates them
    # with the **committed fixture's own processor ids** — they cannot be
    # randomized, since the lifecycle resolves a delivery by matching the
    # payload's ids and a fresh one would produce `unknown_customer` instead of a
    # subscription. So the two tests that use that fixture need the rows cleared
    # between them, and `customers`/`plans` are both unique on the column that
    # would otherwise collide.
    #
    # This is the price of `use_transactional_tests = false`, and it is why the
    # list is explicit rather than a blanket truncation: this file is the only
    # one in the repository whose rows outlive its own test, so the blast radius
    # is written down instead of implied.
    #
    # `setup` matters as much as `teardown`: a test that died mid-flight leaves
    # rows behind, and the next test asserting a count would then fail for a
    # reason of its own.
    def clear_written_tables
      Subscription.delete_all
      ProcessorWebhook.delete_all
      OutboxEvent.delete_all
      Plan.delete_all
      Customer.delete_all
    end

    # A rendezvous for exactly two parties, with no timeout and no sleeping.
    #
    # Each caller increments a count under a mutex and waits on a condition
    # variable until the count reaches two. `wait` releases the mutex, so the
    # second arrival is never blocked by the first — and a `broadcast` with
    # nobody waiting yet is harmless, because the first arrival then waits for a
    # count that has not been reached.
    #
    # There is deliberately no timeout. A timeout here would be a sleep with a
    # nicer name, and it would convert a deadlock into a flake. The only thing
    # between a thread starting and reaching the barrier is building an
    # `Ingestion` and reading a committed fixture file — neither of which can
    # raise for a payload this suite has been posting all along — so both
    # parties are guaranteed to arrive.
    class BothArrived
      def initialize
        @mutex = Mutex.new
        @open = ConditionVariable.new
        @arrived = 0
      end

      def wait_for_the_other
        @mutex.synchronize do
          @arrived += 1
          @open.broadcast
          @open.wait(@mutex) while @arrived < 2
        end
      end
    end
end
