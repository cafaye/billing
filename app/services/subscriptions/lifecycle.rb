module Subscriptions
  # Raised when a verified processor event cannot be applied. It carries a
  # machine-readable `reason` and nothing else: the delivery row records the
  # reason, and the reason is the whole message a human gets.
  #
  # Deliberately *not* `Webhooks::Ignored`. The transport decides what to do with a
  # refusal — on the webhook path it is recorded and answered 200 — and this class
  # says only that the event could not be applied. Keeping them apart means the
  # domain does not know it is being called from a webhook, and a caller that
  # wanted a different answer could give one.
  class Refused < Error
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("refused: #{reason}")
    end
  end

  # Applies one verified processor event to the subscriptions table, and returns
  # the event that change produced.
  #
  # This is the **only** writer of a subscription's state and the only thing that
  # emits a subscription's events. There is no `after_update` on `Subscription` and
  # no branch of the API that changes a status: `POST /v1/subscriptions/:id/cancel`
  # asks the processor to cancel and waits for the webhook that follows, and the
  # row moves when the event arrives. One writer means there is one answer to "what
  # is this subscription's status", and it comes from the party that can bill.
  #
  # The event type is **derived from what happened to the row**, not taken from the
  # processor's event type. A deletion that arrives before its creation creates a
  # `canceled` row and is therefore a cancellation; an update that arrives first
  # would create an active row and be therefore a start. A mapping keyed on the
  # processor's type would publish `billing.subscription.updated` for a
  # subscription nobody has ever seen start.
  #
  # ## A deletion that arrives before its creation
  #
  # The one genuinely interesting case, and the reason the state machine is a table
  # rather than a `case`. A `customer.subscription.deleted` for a subscription this
  # service has never seen creates a `canceled` row rather than being dropped. It
  # is the only statement about that subscription that has arrived, and dropping it
  # would leave an active row — and active rows grant entitlements — for something
  # the processor says is gone. The `created` that follows is then refused by the
  # machine's terminal rule, so the subscription is never started and never grants
  # anything. A subscriber that was created and canceled inside one delivery window
  # ends up recorded as canceled, which is the truth.
  class Lifecycle
    # The three processor types this lifecycle acts on, and the cafaye event each
    # of them can become. The same three the outbox and the manifest declare, so a
    # type cannot be emitted that core's catalog does not list.
    CREATED = "customer.subscription.created".freeze
    UPDATED = "customer.subscription.updated".freeze
    DELETED = "customer.subscription.deleted".freeze

    TYPES = [ CREATED, UPDATED, DELETED ].freeze

    STARTED_EVENT = "billing.subscription.started".freeze
    UPDATED_EVENT = "billing.subscription.updated".freeze
    CANCELED_EVENT = "billing.subscription.canceled".freeze

    # The fields on the row a processor event can set. `last_processor_event_at` is
    # not one of them: it is this service's ordering bookkeeping and it changes on
    # every delivery, so counting it would report a change where none happened.
    STATE_ATTRIBUTES = %w[
      account_id customer_id plan_id status current_period_start current_period_end
      cancel_at_period_end canceled_at
    ].freeze

    # What the lifecycle produced: the row it wrote, the type to publish, the
    # payload, and the time the change happened. A value object so a handler cannot
    # emit half an event.
    Applied = Data.define(:subscription, :event_type, :data, :event_time) do
      # core's envelope `subject`: the entity the event is about. This service's own
      # subscription id, which is what lets a consumer join `started`, `updated` and
      # `canceled` without a lookup table — and which core's started schema says must
      # equal the payload's `subscription_id`.
      def subject
        subscription.id
      end
    end

    def initialize(data:, event_time:)
      @data = data
      @event_time = event_time
    end

    # => Applied. Raises `Refused` with a reason, which the webhook path records on
    # the delivery row and answers 200.
    def call(type)
      raise Refused, "unknown_subscription_event_type" unless TYPES.include?(type)

      subscription = Subscription.find_by(processor_subscription_id: processor_subscription_id)
      transition = StateMachine.new(subscription&.status, data.fetch("status"))

      # The machine first, and the reason it gives, because "nothing revives a
      # canceled subscription" is the rule a subscriber is relying on and it must
      # not be reported as something incidental.
      raise Refused, transition.reason unless transition.legal?

      # An update is not a creation. We do not know when this subscription started,
      # so publishing a start off an update would be a guess about a fact a consumer
      # would then rely on. The `created` that precedes it chronologically still
      # arrives.
      raise Refused, "no_subscription_to_update" if subscription.nil? && type == UPDATED

      from = subscription&.status
      apply(subscription, from, transition)
    end

    private
      attr_reader :data, :event_time

      def processor_subscription_id
        data["subscription_id"]
      end

      def customer
        # The reference this service put in the subscription's metadata at Checkout
        # time, and the processor's own id for the customer. Both are consulted
        # because a customer created through /v1 has a null `processor_customer_id`
        # until its first subscription tells us what the processor calls it.
        resolve(
          data["cafaye_customer_id"] && Customer.find_by(id: data["cafaye_customer_id"]),
          Customer.find_by(processor_customer_id: data["customer_id"]),
          "unknown_customer"
        )
      end

      def plan
        resolve(Plan.find_by(processor_price_id: data["price_id"]), nil, "unknown_plan")
      end

      # A missing reference is a refusal, not a correction. A subscription this
      # service cannot attach to a customer and a plan of its own is not one it
      # bills, and inventing either would put a price on an account that never
      # asked for it.
      def resolve(found, fallback, reason)
        return found if found
        return fallback if fallback

        raise Refused, reason
      end

      def apply(subscription, from, transition)
        existed = !subscription.nil?
        subscription ||= Subscription.new

        subscription.assign_attributes(attributes)
        raise Refused, "no_change_to_record" if existed && !changes_anything?(subscription)

        # The processor's own clock, not this service's. It is the only thing that
        # can tell a delivery that arrived late from one that arrived now, and it is
        # written in the same statement as the state so the two cannot disagree about
        # which event the row reflects.
        subscription.last_processor_event_at = event_time
        subscription.save!

        type = event_type(existed: existed, from: from)
        Applied.new(subscription, type, payload(subscription, type), event_time)
      end

      def changes_anything?(subscription)
        STATE_ATTRIBUTES.any? { |attribute| subscription.will_save_change_to_attribute?(attribute) }
      end

      def attributes
        {
          account_id: customer.owner_id,
          customer_id: customer.id,
          plan_id: plan.id,
          # The processor's own id, and the key every later delivery is resolved by.
          # It is not in `STATE_ATTRIBUTES`: it is set once, at creation, and never
          # changes — a subscription that changed processor id would be a different
          # subscription, and the unique index already says so.
          processor_subscription_id: processor_subscription_id,
          status: data.fetch("status"),
          current_period_start: parse_time(data["current_period_start"]),
          current_period_end: parse_time(data["current_period_end"]),
          # `== true` rather than the raw value, so a processor that sent the string
          # "false" leaves the flag off instead of making it truthy.
          cancel_at_period_end: data["cancel_at_period_end"] == true,
          canceled_at: parse_time(data["canceled_at"])
        }
      end

      # Derived from what happened to the row. A row that did not exist and is now
      # live has started; a row that has just become canceled has been canceled — and
      # that includes a row that was *born* canceled, which is what a deletion that
      # overtook its own creation produces. A row that is still live has been updated.
      def event_type(existed:, from:)
        return CANCELED_EVENT if terminal?(from: from, to: data.fetch("status"))
        return STARTED_EVENT unless existed

        UPDATED_EVENT
      end

      def terminal?(from:, to:)
        to == "canceled" && from != "canceled"
      end

      # The payload.
      #
      # `billing.subscription.started` is the one event core ships a payload schema
      # for, and that schema is closed with `additionalProperties: false` and names
      # exactly eight fields. A start therefore carries those eight and nothing
      # else, and `test/contract/` holds this list against core's actual file — the
      # day core names a ninth, that test fails and the decision becomes explicit
      # rather than a silently invalid event.
      #
      # The other two have no schema yet, so they carry the same eight plus the
      # facts a consumer has to act on them: the period, the cancellation intent, the
      # time it took effect, and the processor's own ids. That asymmetry is
      # deliberate and recorded, and the contract test asserts that core still ships
      # no schema for them — so the day it does, this file is visited.
      def payload(subscription, type)
        core_payload(subscription).merge(type == STARTED_EVENT ? { "started_at" => started_at } : detail_payload)
      end

      def core_payload(subscription)
        payload = {
          "subscription_id" => subscription.id,
          "plan_id" => plan.id,
          "account_id" => customer.owner_id,
          "status" => subscription.status,
          "currency" => plan.currency
        }
        # A field the processor did not send is absent rather than defaulted: a
        # default that silently fills a gap in the weakest input in the system is how
        # a customer ends up on a quantity nobody chose.
        payload["quantity"] = data["quantity"] if data["quantity"].is_a?(Integer)
        # core describes `trial_ends_at` as present only while the subscription is
        # trialing, and that is what it does here — a null when trialing with no end
        # date, absent otherwise.
        payload["trial_ends_at"] = data["trial_ends_at"] if subscription.status == "trialing"
        payload
      end

      # `started_at` is on the start event only. core defines it as "when the
      # subscription became active, always equal to the envelope's time", which is
      # true of a start and false of an update — on an update the envelope's time is
      # when the *change* happened, and stamping it as the start would be a lie
      # about a fact a consumer renders a timeline from.
      def started_at
        event_time.utc.iso8601
      end

      def detail_payload
        {
          "current_period_start" => data["current_period_start"],
          "current_period_end" => data["current_period_end"],
          "cancel_at_period_end" => data["cancel_at_period_end"] == true,
          "canceled_at" => data["canceled_at"],
          "processor" => data["processor"],
          "processor_event_id" => data["processor_event_id"],
          "processor_subscription_id" => processor_subscription_id
        }
      end

      def parse_time(value)
        value.is_a?(String) ? Time.iso8601(value) : nil
      end
  end
end
