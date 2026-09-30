module Subscriptions
  # The subscription lifecycle, as one object with named transitions.
  #
  # Everything this service knows about which subscription states exist, and
  # which may follow which, is in the `LEGAL` table below. There is no other
  # place: a controller does not contain a `case status`, and neither does the
  # webhook path. One table means the set of *impossible* transitions is
  # readable, which is the property that actually matters and the one a pile of
  # conditionals cannot show you.
  #
  # The object is pure. It takes a from-status and a to-status and answers; it
  # never touches the database, never reads the clock and never calls the
  # processor. That is what makes the whole cross product of states testable as a
  # table rather than reached through five fixtures and a webhook — see
  # test/services/subscriptions/state_machine_test.rb, which asserts every legal
  # and every illegal transition.
  #
  # Three refusals, and they are refusals rather than corrections on purpose:
  #
  #   * **`canceled` is terminal.** Nothing revives it, not even a second
  #     `customer.subscription.deleted` that says `canceled` again. This is the
  #     rule that makes out-of-order delivery safe: an `updated` that was queued
  #     before a `deleted` and arrives after it cannot put a canceled
  #     subscription back into service.
  #   * **A subscription cannot be born canceled, past_due or unpaid.** A
  #     deletion arriving before its creation is a no-op, not a second
  #     contradictory row. The `created` that follows it is still accepted.
  #   * **A status the processor uses and this service does not model is an
  #     error, not a value to guess at.** `incomplete`, `incomplete_expired` and
  #     `paused` are all refused by the constructor, so the caller must park the
  #     delivery with a reason instead of writing a row that says a subscription
  #     is `active` when the processor says it is `incomplete`.
  #
  # Arrears are the one thing that is deliberately permissive: `past_due` and
  # `unpaid` can go back to `active`, because a payment that succeeds takes them
  # there and refusing it would strand a customer who has paid.
  class StateMachine
    # from => to => true when the transition is legal. `nil` is the key for "no
    # subscription exists yet", and only a live status may start one.
    #
    # Read down the `nil` row and it is the only way a row can come into
    # existence; read across the `canceled` row and it is the only status nothing
    # can leave.
    LEGAL = {
      nil => { "active" => true, "trialing" => true, "past_due" => false, "unpaid" => false, "canceled" => false },
      "trialing" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
      "active" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
      "past_due" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
      "unpaid" => { "active" => true, "trialing" => true, "past_due" => true, "unpaid" => true, "canceled" => true },
      "canceled" => { "active" => false, "trialing" => false, "past_due" => false, "unpaid" => false, "canceled" => false }
    }.freeze

    attr_reader :from, :to

    def initialize(from, to)
      @from = from
      @to = to

      # Refused here rather than defaulted. A caller holding `incomplete` has
      # something this service cannot represent, and the right answer is for the
      # delivery to be parked with a reason — not for a row to be written saying
      # something else.
      raise ArgumentError, "unknown target status #{to.inspect}" unless Subscription::STATUSES.include?(to)
      raise ArgumentError, "unknown from status #{from.inspect}" unless from.nil? || Subscription::STATUSES.include?(from)
    end

    def legal?
      LEGAL.fetch(from).fetch(to)
    end

    # Why a transition is refused, or nil when it is allowed. The reason is what
    # lands in `processor_webhooks.error` and what a human reads when a
    # subscription did not do what a webhook said it should have, so the strings
    # are part of the contract rather than prose.
    def reason
      return nil if legal?
      return "canceled_is_terminal" if from == "canceled"
      return "no_subscription_to_#{refusal_for_creation}"

      # Unreachable: the table is total over known statuses, so a `nil` here
      # means the table and the model disagree, which is a bug rather than a
      # transition.
      raise "no transition rule for #{from.inspect} -> #{to.inspect}"
    end

    # Whether applying this transition would create the row. Only a start from
    # nothing does; everything else updates a row that is already there.
    def creates?
      from.nil? && legal?
    end

    def terminal?
      Subscription::TERMINAL_STATUSES.include?(from)
    end

    def live?
      Subscription::LIVE_STATUSES.include?(to)
    end

    private
      # The reason for a refusal that is about a subscription not existing yet.
      # The verb is the event that was refused, so the recorded reason names what
      # was asked for rather than restating the rule.
      def refusal_for_creation
        { "canceled" => "cancel", "past_due" => "be_past_due", "unpaid" => "be_unpaid" }.fetch(to)
      end
  end
end
