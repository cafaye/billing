require "test_helper"

# The state machine, as a table.
#
# This is the packet's central object and it is tested as one: every legal
# transition and every illegal one, from every status, with the reason each
# refusal carries. A state machine tested one branch at a time is a pile of
# conditionals with tests attached, and the property that matters — *which
# transitions are impossible* — is invisible unless the whole grid is asserted.
#
# It is pure. It reads a from-status and a to-status and answers, and it never
# touches the database, which is why the whole cross product of six froms
# (including "no subscription") and five tos can be asserted here rather than
# reached through five fixtures and a webhook.
class Subscriptions::StateMachineTest < ActiveSupport::TestCase
  # from => to => legal?
  #
  # Read this as the whole contract. Every row is asserted by the loop below,
  # and a status added to `Subscription::STATUSES` without a row here fails the
  # "covers every status" test rather than going unchecked.
  LEGAL_TRANSITIONS = {
    # Nothing exists. The only way a subscription appears is a start, and only
    # a live one: `canceled` is unreachable from nothing, which is what makes a
    # deletion arriving before its creation a no-op rather than a second,
    # contradictory row.
    nil => { "active" => true, "trialing" => true, "past_due" => false, "unpaid" => false, "canceled" => false },
    # A trial is live and can become anything live, or end.
    "trialing" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
    "active" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
    # Arrears recover. A payment that succeeds takes a `past_due` or `unpaid`
    # subscription back to `active`, and refusing that would strand a customer
    # who has paid.
    "past_due" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
    "unpaid" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
    # Terminal. Nothing leaves it, not even back to the status it was in when it
    # was canceled. The row is evidence of what happened, and nothing in a signed
    # webhook can make it true that a canceled subscription is running again.
    "canceled" => { "active" => false, "trialing" => false, "past_due" => false, "unpaid" => false, "canceled" => false }
  }.freeze

  # The statuses this build does not model, and must not quietly absorb. Stripe
  # sends them; a subscription that lands in one of them is parked with a reason
  # rather than coerced into one of the five, because a row that says `active` for
  # a subscription the processor calls `incomplete` grants entitlements nobody
  # has paid for.
  UNMODELLED_STATUSES = %w[incomplete incomplete_expired paused].freeze

  # Every "from", including the one that is not a status: no subscription at all.
  FROMS = ([ nil ] + Subscription::STATUSES).freeze

  test "the machine's table covers every status this service stores, and one for nothing existing" do
    assert_equal FROMS.sort_by(&:to_s), LEGAL_TRANSITIONS.keys.sort_by(&:to_s)
  end

  test "the machine's table names every status as a target" do
    LEGAL_TRANSITIONS.each_value do |targets|
      assert_equal Subscription::STATUSES.sort, targets.keys.sort
    end
  end

  FROMS.each do |from|
    Subscription::STATUSES.each do |to|
      expected = LEGAL_TRANSITIONS.fetch(from).fetch(to)

      test "#{from || 'no subscription'} may #{expected ? '' : 'not '}become #{to}" do
        machine = Subscriptions::StateMachine.new(from, to)

        assert_equal expected, machine.legal?
        assert_equal expected, machine.legal?, "the machine is pure: two instances agree"
      end
    end
  end

  # "It is refused" and "the record says why" are different claims, and the
  # second is the one a human reads in `processor_webhooks.error` at 3am.
  test "a refusal always carries a reason" do
    FROMS.product(Subscription::STATUSES).each do |from, to|
      machine = Subscriptions::StateMachine.new(from, to)

      if machine.legal?
        assert_nil machine.reason
      else
        assert_predicate machine.reason, :present?, "#{from.inspect} -> #{to} was refused with no reason"
      end
    end
  end

  test "a subscription that does not exist yet cannot become canceled" do
    machine = Subscriptions::StateMachine.new(nil, "canceled")

    assert_not machine.legal?
    assert_equal "no_subscription_to_cancel", machine.reason
  end

  test "a subscription that does not exist yet cannot become past_due" do
    machine = Subscriptions::StateMachine.new(nil, "past_due")

    assert_not machine.legal?
    assert_equal "no_subscription_to_be_past_due", machine.reason
  end

  test "a subscription that does not exist yet cannot become unpaid" do
    machine = Subscriptions::StateMachine.new(nil, "unpaid")

    assert_not machine.legal?
    assert_equal "no_subscription_to_be_unpaid", machine.reason
  end

  test "nothing revives a canceled subscription" do
    Subscription::STATUSES.each do |to|
      machine = Subscriptions::StateMachine.new("canceled", to)

      assert_not machine.legal?
      assert_equal "canceled_is_terminal", machine.reason
    end
  end

  test "a canceled subscription stays canceled when the processor repeats the cancellation" do
    # The one case where the refusal could be read as a bug: Stripe sends
    # `customer.subscription.deleted` for a subscription already deleted, and
    # both deliveries carry `canceled`. The second is a no-op, not an error, and
    # it must not move the row.
    machine = Subscriptions::StateMachine.new("canceled", "canceled")

    assert_not machine.legal?
    assert_equal "canceled_is_terminal", machine.reason
  end

  UNMODELLED_STATUSES.each do |status|
    test "#{status} is not a status this service models" do
      assert_not_includes Subscription::STATUSES, status
    end

    test "the machine refuses #{status} rather than guessing what it meant" do
      assert_raises(ArgumentError) { Subscriptions::StateMachine.new("active", status) }
    end
  end

  test "the machine refuses a from-status it does not know" do
    assert_raises(ArgumentError) { Subscriptions::StateMachine.new("incomplete", "active") }
  end

  test "only a start creates a row, and only a live one" do
    assert_predicate Subscriptions::StateMachine.new(nil, "active"), :creates?
    assert_predicate Subscriptions::StateMachine.new(nil, "trialing"), :creates?
    refute_predicate Subscriptions::StateMachine.new("active", "active"), :creates?
    refute_predicate Subscriptions::StateMachine.new("active", "canceled"), :creates?
  end

  test "canceled is the only terminal state, and the machine agrees with the model" do
    assert_equal %w[canceled], Subscription::TERMINAL_STATUSES
    refute_predicate Subscriptions::StateMachine.new("active", "canceled"), :terminal?
    assert_predicate Subscriptions::StateMachine.new("canceled", "canceled"), :terminal?
  end

  test "the machine agrees with the model about which statuses are live" do
    Subscription::STATUSES.each do |status|
      machine = Subscriptions::StateMachine.new(status, status)

      assert_equal Subscription::LIVE_STATUSES.include?(status), machine.live?
    end
  end
end
