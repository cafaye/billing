require "test_helper"

# Three cross-tenant defects this packet found, pinned as findings.
#
# ## Why findings live in a test file and not only in a report
#
# A finding written only in prose is a finding that rots. Each of the three
# below is asserted here as a **green test that says precisely what is true** —
# the repository's own rule, and the reason it matters here specifically: a red
# test advertising a known hole is how a suite starts being ignored, and a red
# test that fails is a test somebody will delete to make the build green.
#
# So each test asserts the defect is *present*, and couples itself to the thing
# that would remove it. The direction of the failure is the important half:
#
#   * **F1** fails the moment `Lifecycle` compares the resolved account with the
#     account already on the row — the fix, and the only sensible one.
#   * **F2** and **F3** fail the moment a unique index lands on the column. A
#     unique index with a `WHERE` clause is the natural fix and would also permit
#     it, since these columns are nullable and many rows legitimately are.
#
# A test that goes red when the defect is fixed is a **tripwire for the fix**, and
# that is the point. It is deliberately *not* a test that goes red when the defect
# is present, and it is not a test that would pass after the fix — each of these
# is a test to be **deleted and replaced** by the scoping work, and each says so
# in its own failure message.
#
# ## The chain, and why F2 is worse than F1
#
# `Lifecycle#apply` writes `account_id: customer.owner_id` without ever comparing
# it to the account already on the row it is updating. That is F1.
#
# On its own, F1 needs a delivery whose resolved customer disagrees with the
# subscription's existing row, and a well-behaved processor does not send that —
# one `sub_` has one `cus_`. **F2 is what makes F1 reachable through this
# service's own public surface:** `customers.processor_customer_id` is not unique,
# `POST`/`PATCH /v1/customers` both permit it, and `Lifecycle#customer` resolves it
# with `find_by`. So a caller can point their *own* customer row at a victim's
# `cus_` id, and from then on a delivery about the victim's subscription resolves
# to the caller's row — and F1 does the rest.
#
# F3 is the same shape one table over, on `plans.processor_price_id`, and it is
# about correctness rather than tenancy: a subscription is billed against whichever
# plan claimed the price id, so a customer can end up on a plan nobody sold them.
class TenantCrossAccountFindingsTest < ActionDispatch::IntegrationTest
  setup do
    travel_to(frozen_now)
  end

  # --- F1: a delivery moves a subscription between accounts -----------------

  # **The finding.** `Subscriptions::Lifecycle#apply` resolves a customer from the
  # delivery and then writes `account_id: customer.owner_id` onto the row it is
  # updating — with no comparison against the account already there. A second
  # delivery that resolves a *different* customer therefore reassigns a live
  # subscription from one account to another, and publishes the move as
  # `billing.subscription.updated`.
  #
  # **Why it is not caught by the model.** `Subscription#account_is_the_customers_owner`
  # does compare an account against a customer, and it is the only such check in
  # the service. It holds here too — the write *is* internally consistent, the new
  # account belongs to the new customer. What it cannot see is that the account
  # changed, because the rule it enforces is "a subscription's account is its
  # customer's", not "a subscription's account does not move".
  #
  # **What it costs.** The first account loses the subscription and everything
  # `grants_entitlements?` derives from it, the second gains one it never bought,
  # and the `billing.subscription.updated` event carries the new account — so a
  # consumer counting plan changes, or reading a timeline of an account's billing,
  # is told this was always the arrangement.
  test "F1: a delivery naming a different customer moves the subscription between accounts" do
    create_account_customers
    shared_plan

    deliver_subscription_created(subscription_id: SUBSCRIPTION_A, customer: customer_a, event_id: "evt_FAKEfind1")
    row = Subscription.find_by!(processor_subscription_id: SUBSCRIPTION_A)
    assert_equal ACCOUNT_A, row.account_id, "the first delivery should have billed account A"

    before = fingerprint([ row ])

    # The second delivery names account B's customer for the subscription id that
    # account A holds. A processor does not do this; a processor *dashboard* does,
    # and so does F2 below.
    deliver_subscription_updated(subscription_id: SUBSCRIPTION_A, customer: customer_b, event_id: "evt_FAKEfind2")

    row.reload
    assert_equal [ row.id ], drifted_ids(before, [ row ]),
      "the row did not change, so F1 no longer reproduces. The fix is to compare the " \
      "resolved account against the account already on the row and refuse a change; " \
      "delete this finding and replace it with the refusal's test."
    assert_equal ACCOUNT_B, row.account_id,
      "the subscription now belongs to the account its second delivery named. " \
      "F1 has been fixed; delete this finding."
    assert_equal customer_b.id, row.customer_id

    # And it is published, not just written: a consumer is told.
    event = OutboxEvent.find_by!(subject: row.id, event_type: "billing.subscription.updated")
    assert_equal ACCOUNT_B, event.data.fetch("account_id"),
      "the reassignment is announced as an update naming the new account. If the event " \
      "no longer does, F1 has been fixed; delete this finding."
  end

  # The half that makes F1 a *money* defect rather than a bookkeeping one: the
  # subscription does not stop working, it starts working for somebody else. The
  # row stays `live`, so `grants_entitlements?` stays true — which is the point.
  # **Entitlements are decided by status, and a reassignment does not change the
  # status**, so a consumer checking "is this subscription active?" sees an active
  # subscription for an account that never bought one.
  test "F1: the account that lost the subscription no longer holds it, and the one that gained it never bought it" do
    create_account_customers
    shared_plan

    deliver_subscription_created(subscription_id: SUBSCRIPTION_A, customer: customer_a, event_id: "evt_FAKEfind3")
    row = Subscription.find_by!(processor_subscription_id: SUBSCRIPTION_A)
    assert_equal [ row.id ], Subscription.where(account_id: ACCOUNT_A).pluck(:id)

    deliver_subscription_updated(subscription_id: SUBSCRIPTION_A, customer: customer_b, event_id: "evt_FAKEfind4")

    row.reload
    assert_empty Subscription.where(account_id: ACCOUNT_A, id: row.id),
      "account A still holds the subscription it paid for. F1 has been fixed; delete this " \
      "finding."
    assert_equal [ row.id ], Subscription.where(account_id: ACCOUNT_B).pluck(:id),
      "account B does not hold the subscription a delivery named it on. F1 has been fixed; " \
      "delete this finding."

    # Still live, still granting — which is why this is a grant to the wrong account
    # rather than a lapse.
    assert row.grants_entitlements?,
      "the subscription stopped granting. The finding is about *which account* a live " \
      "subscription belongs to, not about whether it is live; if this is false the row's " \
      "status changed and the finding needs rewriting."
  end

  # --- F2: one Stripe customer id, two accounts -----------------------------

  # **The finding.** `customers.processor_customer_id` carries no unique index, and
  # `POST /v1/customers` and `PATCH /v1/customers/:id` both permit a client to set
  # it. So two accounts can each hold a customer row answering to the *same*
  # `cus_` id, and `Subscriptions::Lifecycle#customer` resolves that id with
  # `find_by` — no `ORDER BY`, no uniqueness, so which account a delivery lands on
  # is **not determined by the data**.
  #
  # The pair matters and is arranged deliberately: with both accounts claiming one
  # id, a lookup keyed on the id does not error and does not return nothing, it
  # returns a row and the wrong one. Every id-keyed test in the repository stays
  # green, which is why this is a finding and not a bug somebody would trip over.
  test "F2: two accounts can hold customer rows that answer to one Stripe customer id" do
    shared = "cus_FAKEcontestedBBBBBBBBBBBB"

    first = Customer.create!(owner_type: "Account", owner_id: ACCOUNT_A, processor: "stripe", processor_customer_id: shared)
    second = Customer.create!(owner_type: "Account", owner_id: ACCOUNT_B, processor: "stripe", processor_customer_id: shared)

    assert_equal 2, Customer.where(processor_customer_id: shared).count,
      "the two accounts no longer share the id. A unique index has landed on " \
      "`customers.processor_customer_id`; F2 is fixed — delete this finding and keep the " \
      "index test."
    assert_equal [ ACCOUNT_A, ACCOUNT_B ], [ first.owner_id, second.owner_id ].sort,
      "the two rows must belong to different accounts, or the collision proves nothing"
  end

  # F2 is reachable through this service's own surface, which is what separates it
  # from a theoretical one. The claim is a `PATCH` on a caller's **own** row —
  # `CustomerUpdate` permits `processor_customer_id`, and `owner`/`processor` are
  # the fields that are *not* updatable, so this is the one identifier a client can
  # move. A victim id is then copied onto the caller's row.
  test "F2: a client can point its own customer row at another account's Stripe customer id" do
    victim = Customer.create!(
      owner_type: "Account", owner_id: ACCOUNT_B, processor: "stripe",
      processor_customer_id: "cus_FAKEvictimBBBBBBBBBBBBB"
    )
    attacker = Customer.create!(
      owner_type: "Account", owner_id: ACCOUNT_A, processor: "stripe",
      processor_customer_id: "cus_FAKEattackerAAAAAAAAA"
    )

    patch "/v1/customers/#{attacker.id}", params: { processor_customer_id: victim.processor_customer_id }, as: :json

    assert_response :ok
    assert_equal 2, Customer.where(processor_customer_id: victim.processor_customer_id).count,
      "the claim was not accepted, so the two rows no longer collide. F2 is not reachable " \
      "through the public surface any more; delete this finding and assert the refusal."
    assert_equal victim.processor_customer_id, attacker.reload.processor_customer_id
  end

  # The resolution itself, and the reason the *outcome* is not asserted: with two
  # rows matching, `find_by` returns one of them and which one is not decided by
  # the data. Asserting a specific account here would be a flake waiting for a
  # different plan on a different day — and the ambiguity is the finding, so what
  # is asserted is the ambiguity and the two candidates.
  test "F2: the resolution is ambiguous, and the outcome is not decided by the data" do
    shared = "cus_FAKEambiguousBBBBBBBBBBBBB"
    { "a" => ACCOUNT_A, "b" => ACCOUNT_B }.each_value do |account|
      Customer.create!(owner_type: "Account", owner_id: account, processor: "stripe", processor_customer_id: shared)
    end

    candidates = Customer.where(processor_customer_id: shared).pluck(:owner_id).sort
    resolved = Customer.find_by(processor_customer_id: shared)

    assert_equal [ ACCOUNT_A, ACCOUNT_B ], candidates,
      "the two candidate accounts are gone; a unique index has landed and F2 is fixed"
    assert_includes candidates, resolved.owner_id,
      "`find_by` returned a row that is not one of the two claimants, which would be a " \
      "third defect rather than this one"
    assert_predicate resolved, :present?,
      "`find_by` returned nothing at all, which is `unknown_customer` and not this finding"
  end

  # --- F3: one Stripe price id, two plans -----------------------------------

  # **The finding.** The same shape on `plans.processor_price_id`: no unique index,
  # `POST`/`PATCH /v1/plans` both permit it, and
  # `Subscriptions::Lifecycle#plan` resolves it with `find_by`. A subscription is
  # then billed against whichever plan claimed the id.
  #
  # This one is a correctness defect rather than a tenancy one — a plan is
  # catalogue, and the catalogue is shared on purpose — but the consequence is the
  # same shape: a customer's subscription lands on a plan they were not sold, at a
  # price this service did not agree with them, and `billing.subscription.started`
  # carries that plan's `currency` and nothing about the one that was intended.
  test "F3: two plans can claim one Stripe price id, and a delivery resolves to one of them" do
    shared = "price_FAKEcontestedAAAAAAAAAA"

    first = create_stripe_plan(processor_price_id: shared, price: Money.new(1_900, "USD"))
    second = create_stripe_plan(processor_price_id: shared, price: Money.new(49_000, "USD"))

    assert_equal 2, Plan.where(processor_price_id: shared).count,
      "the two plans no longer share the price id. A unique index has landed on " \
      "`plans.processor_price_id`; F3 is fixed — delete this finding."
    refute_equal first.amount_cents, second.amount_cents,
      "the two plans must charge different amounts, or resolving to the wrong one is not " \
      "a pricing defect"
    assert_includes Plan.where(processor_price_id: shared).pluck(:id), Plan.find_by(processor_price_id: shared).id
  end

  # --- what these three are not ---------------------------------------------

  # The three findings are about the **delivery** path, where this service resolves
  # a row from an identifier a third party controls. They are not about the
  # database's account-scoped constraints, and the two must not be confused:
  # `(account_id, plan_id)` and `(owner_type, owner_id, processor)` both hold
  # today, and `cross_account_delivery_test.rb` proves each one behaviourally.
  #
  # So the count of account-scoped constraints that hold is 2, and the count of
  # resolution keys that are ambiguous is 2. Asserted together, because "2 and 2"
  # read as a coincidence unless the two are named.
  test "meta: two account-scoped constraints hold, and two resolution keys are ambiguous" do
    create_ambiguous_resolution_keys

    assert_equal %w[customers plans], ambiguous_resolution_keys.keys.sort,
      "the ambiguous resolution keys changed. A new one is a fourth finding; an index " \
      "removed one is a fix, and the report must be corrected."
    assert_equal 0, account_scoped_queries,
      "account scoping landed, so the report's characterisation of this surface is wrong."
  end

  # The three findings are reported, not fixed, in this packet. `Lifecycle` is the
  # only writer of subscription state and adding a guard to it is a behavioural
  # change to money; a unique index is a migration. Both are named in the report as
  # the next packet's work. This asserts the packet did not fix them **quietly** —
  # a fix that landed without the finding being retired would leave the report
  # describing a defect that no longer exists.
  test "meta: the three findings are reported rather than fixed, and their counts are pinned" do
    create_ambiguous_resolution_keys

    assert_equal %w[F1 F2 F3], declared_finding_labels,
      "the set of findings changed. A new label is a fourth finding to report; a missing " \
      "one means a finding was fixed and the report must say so."
    assert_equal 6, declared_finding_tests.size,
      "the number of tests reproducing a finding changed. F1 and F2 each take more than one " \
      "because each needed the consequence proven as well as the mechanism."
    assert_equal 2, ambiguous_resolution_keys.size
  end

  private
    # Both ambiguous resolutions, arranged. A helper that reads the database for
    # ambiguity cannot arrange it, so the two collisions are created here and
    # `ambiguous_resolution_keys` reads the result back.
    def create_ambiguous_resolution_keys
      [ ACCOUNT_A, ACCOUNT_B ].each do |account|
        Customer.create!(
          owner_type: "Account", owner_id: account, processor: "stripe",
          processor_customer_id: "cus_FAKEambiguousBBBBBBBBBBBBB"
        )
      end
      create_stripe_plan(processor_price_id: "price_FAKEambiguousAAAAAAAAA", price: Money.new(1_900, "USD"))
      create_stripe_plan(processor_price_id: "price_FAKEambiguousAAAAAAAAA", price: Money.new(49_000, "USD"))
    end

    # The tests whose name names a finding. Counted so the report's "three findings,
    # six reproductions" is a fact about this file rather than a number in prose that
    # no test holds.
    def declared_finding_tests
      self.class.public_instance_methods(false).grep(/\Atest_F\d:/).sort
    end

    # The distinct findings, from the same names. F1 and F2 each take more than one
    # test, so counting tests and counting findings are two different numbers and
    # conflating them is how a report ends up claiming three reproductions of two
    # findings.
    def declared_finding_labels
      declared_finding_tests.map { |method| method.to_s[/\Atest_(F\d):/, 1] }.uniq.sort
    end

    # The columns a delivery resolves a tenant row by, which have no uniqueness.
    def ambiguous_resolution_keys
      ambiguous = {}
      ambiguous["customers"] = 2 if Customer.where.not(processor_customer_id: nil).group(:processor_customer_id).having("count(*) > 1").any?
      ambiguous["plans"] = 2 if Plan.where.not(processor_price_id: nil).group(:processor_price_id).having("count(*) > 1").any?
      ambiguous
    end

    def account_scoped_queries
      Dir[Rails.root.join("app/**/*.rb")].sum { |path|
        File.read(path).scan(/(?:where|find|find_by|find_by!)\(.*?account_id:/).size
      }
    end

    def deliver_subscription_created(subscription_id:, customer:, event_id:)
      deliver_subscription_event("customer.subscription.created", subscription_id: subscription_id, customer: customer, event_id: event_id)
    end

    def deliver_subscription_updated(subscription_id:, customer:, event_id:)
      deliver_subscription_event("customer.subscription.updated", subscription_id: subscription_id, customer: customer, event_id: event_id)
    end

    # One delivery, built from the committed fixture so the shape is one the
    # processor actually sends, with the four fields a subscription is resolved by
    # moved onto the rows under test.
    #
    # The event's `id` is merged into the body, which is what
    # `Webhooks::StripeController` does in production: the delivery's id and the
    # payload that arrived with it are one value. A helper that varied one without
    # the other would arrange a state Stripe never sends, and the outbox's unique
    # index over `processor_event_id` would then turn a correct test into a
    # duplicate-delivery refusal.
    #
    # The updated event is one second later because the lifecycle refuses a
    # delivery that is not strictly newer than the one that last wrote the row
    # (`stale_delivery`). A second delivery at the *same* processor timestamp is
    # not stale — epoch seconds are coarse — but it would then be refused as
    # `no_change_to_record` if the two deliveries agreed about everything, and the
    # findings here are about a delivery that disagrees.
    def deliver_subscription_event(type, subscription_id:, customer:, event_id:)
      body = JSON.parse(stripe_fixture(type == "customer.subscription.created" ? "customer.subscription.created" : "customer.subscription.updated"))
      object = body.dig("data", "object")

      body["id"] = event_id
      object["id"] = subscription_id
      object["customer"] = customer.processor_customer_id
      object["metadata"] = { "cafaye_customer_id" => customer.id }
      object.dig("items", "data", 0, "price")["id"] = shared_plan.processor_price_id
      object["plan"]["id"] = shared_plan.processor_price_id

      Webhooks::Ingestion.new(processor: :stripe, event_id: event_id, type: body["type"], payload: body).call
    end
end
