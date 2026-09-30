module V1
  # /v1/subscriptions — the lifecycle a client drives.
  #
  # ## Nothing here decides a subscription's state
  #
  # Every mutating action asks the processor to do something and returns. The
  # subscription row changes when a webhook says it did, which is the rule the rest
  # of this service follows: the processor is the party that can bill, and a local
  # row that disagreed with it would grant entitlements nobody is paying for.
  # Concretely:
  #
  #   * `create` writes **no** subscription. It creates a Checkout session, because a
  #     subscription does not exist until the payment completes — and the 201 carries
  #     the session, not a resource. Inventing a local row here would mean a sixth
  #     status meaning "we asked", which is a state no processor can report.
  #   * `cancel` and `change_plan` move the processor's subscription and leave the row
  #     alone. A response claiming the subscription is canceled before the processor
  #     has said so would be a lie a client could act on.
  #
  # The exception to "the response is the row" is `change_plan`, which returns a
  # `plan_change` object alongside it. Without it a client has no way to learn that a
  # downgrade is scheduled for the end of the period rather than applied now — the
  # rule lives in `Subscriptions::PlanChange` and is otherwise invisible until a
  # webhook lands. It describes the decision this request made; it is not state, and
  # the subscription's own fields do not change.
  #
  # ## Every problem in a body is reported at once
  #
  # `refuse` records rather than renders, and an action renders once at the end. A
  # client that sent three wrong fields gets three failures, not the first one three
  # times — which is the same rule `render_validation_failure` follows for a model's
  # own errors.
  #
  # ## Open in v0, and the gap is recorded
  #
  # There is no authorization on this controller, so `index` returns every
  # subscription and `create` takes a `customer_id` from the body. Both are the same
  # recorded gap as `CustomersController` (README, "Authorization") and the same
  # resolution: when identity's JWKS verification lands, every query here is scoped
  # by the token's `account_id` and the body stops being the way a customer is
  # named. That is a breaking change to this surface, not a bug fix, and it is why
  # `create` refuses a user-owned customer rather than inventing the account one.
  class SubscriptionsController < BaseController
    # One thing wrong with the request. `code` is core's problem code, `field` is the
    # name the client sent it under, and the message is the sentence.
    Refusal = Data.define(:code, :field, :message) do
      def as_error
        { "field" => field, "code" => "invalid" }
      end
    end

    def index
      render_page(paginate(Subscription.all), ->(subscription) { serialize(subscription) })
    end

    def show
      render json: serialize(subscription_record), status: :ok
    end

    def entitlements
      render json: entitlements_for(subscription_record), status: :ok
    end

    def create
      replayed = replayed_response
      return render_replayed_response(replayed) if replayed

      customer = billable_customer
      plan = sellable_plan
      return render_refusals if refused?
      return if performed?

      session = checkout_for(customer, plan)
      return render_refusals if refused?
      return if performed?

      body = {
        "checkout_session_id" => session.id,
        "checkout_url" => session.url,
        "customer_id" => customer.id,
        "plan_id" => plan.id
      }

      render json: body, status: :created
      remember_response(body)
    end

    def cancel
      replayed = replayed_response
      return render_replayed_response(replayed) if replayed

      subscription = subscription_record
      at_period_end = at_period_end_param
      guard_cancellable!(subscription, at_period_end)
      return render_refusals if refused?
      return if performed?

      ask_processor do
        processor.cancel_subscription(
          processor_subscription_id: subscription.processor_subscription_id,
          at_period_end: at_period_end
        )
      end
      return render_refusals if refused?
      return if performed?

      body = serialize(subscription)
      render json: body, status: :ok
      remember_response(body)
    end

    def change_plan
      replayed = replayed_response
      return render_replayed_response(replayed) if replayed

      subscription = subscription_record
      target = sellable_plan
      guard_changeable!(subscription)
      return render_refusals if refused?
      return if performed?

      change = Subscriptions::PlanChange.new(from: subscription.plan, to: target)
      # The timing decision is the whole answer, and the proration *behaviour* is all
      # that goes to the processor: the amount it bills is the processor's, and there
      # is no code path here that could compute one.
      ask_processor do
        processor.apply_plan_change(
          processor_subscription_id: subscription.processor_subscription_id,
          price_id: change.to_price_id,
          proration_behavior: change.proration_behavior
        )
      end
      return render_refusals if refused?
      return if performed?

      body = serialize(subscription).merge("plan_change" => plan_change(target, change))
      render json: body, status: :ok
      remember_response(body)
    end

    private
      attr_reader :processor

      def initialize(...)
        super
        # Read once per request rather than constructed per call, so a key that
        # rotates mid-request cannot make two calls in one request disagree about
        # which account they are talking to.
        @processor = Processor::StripeClient.current
        @refusals = []
      end

      def subscription_record
        @subscription_record ||= Subscription.find(uuid_param!(params[:id]))
      end

      def checkout_for(customer, plan)
        ask_processor do
          processor.create_checkout_session(
            plan_price_id: plan.processor_price_id,
            customer_reference: customer.id,
            processor_customer_id: customer.processor_customer_id.presence
          )
        end
      end

      # One place the processor is asked, and the one place its refusals become
      # answers. `Subscriptions::PlanChange::Unpriced` and
      # `Money::CurrencyMismatchError` are raised by the plan-change *rule* rather
      # than by the processor and mean the same thing here — this request cannot be
      # carried out as asked — so they are handled alongside.
      def ask_processor
        yield
      rescue Processor::Error, Subscriptions::PlanChange::Error, Money::CurrencyMismatchError => e
        refuse_processor(e)
      end

      # The customer the request named, and the check that it is one this service can
      # bill. A user-owned customer is refused rather than resolved to an account:
      # which account a user belongs to is identity's fact, and no event carrying it
      # is in this build's `consumes`.
      def billable_customer
        customer = find_or_refuse(:customer_id) { Customer.find_by(id: _1) }
        return if customer.nil?

        unless customer.owner_type == Subscription::BILLABLE_OWNER_TYPE
          return refuse(:validation_failed, "customer_id", "belongs to a user, and a subscription is billed to an account")
        end

        customer
      end

      # A plan that is for sale and that the processor can actually charge for. Both
      # checks are here rather than at the processor: a request this service knows
      # cannot work should not be sent and answered with someone else's error.
      def sellable_plan
        plan = find_or_refuse(:plan_id) { Plan.find_by(id: _1) }
        return if plan.nil?
        return refuse(:validation_failed, "plan_id", "is not for sale") unless plan.active
        return refuse(:validation_failed, "plan_id", "has no processor price, so it cannot be bought") if plan.processor_price_id.blank?

        plan
      end

      # A field that must be a uuid, resolved or refused.
      #
      # Absent is a 422 naming the field, because the caller left something out and
      # the body was otherwise fine. Present but not a uuid is a 404, decided before
      # any query — the same rule `uuid_param!` applies to a path segment, and for
      # the same reason: Postgres parses a `uuid` column before Rails gets to decide
      # whether a row exists.
      def find_or_refuse(field)
        value = params[field]
        return refuse(:validation_failed, field, "is required") if value.blank?
        raise ActiveRecord::RecordNotFound unless Identifiers::UUID.match?(value.to_s)

        yield(value) || refuse(:validation_failed, field, "is not a record this service has")
      end

      # A 422 naming the field, not a 400. The body parsed as JSON; it is a field
      # that is missing or wrong, which is core's 422 and not its 400 — a 400 is for
      # syntax the caller could not have known about.
      def at_period_end_param
        return refuse(:validation_failed, "at_period_end", "is required and must be true or false") unless params.key?(:at_period_end)

        value = params[:at_period_end]
        return value if value == true || value == false

        refuse(:validation_failed, "at_period_end", "must be true or false")
      end

      # Two things refuse a cancellation, and they are different.
      #
      # A `canceled` or `unpaid` subscription is a conflict: the request collides
      # with something that already happened, or the processor has stopped collecting
      # and is about to cancel it itself.
      #
      # A `past_due` subscription asked to cancel *at the period end* is a 422 rather
      # than a silent immediate cancellation: there is no further period to serve, and
      # quietly doing something other than what the caller asked is worse than
      # refusing.
      def guard_cancellable!(subscription, at_period_end)
        unless Subscription::ACTIONABLE_STATUSES.include?(subscription.status)
          return refuse(:conflict, "status", "is #{subscription.status}, so there is nothing to cancel")
        end

        return unless at_period_end && subscription.status == "past_due"

        refuse(:validation_failed, "at_period_end",
          "must be false for a past_due subscription: there is no further period to serve")
      end

      def guard_changeable!(subscription)
        return if Subscription::ACTIONABLE_STATUSES.include?(subscription.status)

        refuse(:conflict, "status", "is #{subscription.status}, so its plan cannot be changed")
      end

      # What the processor said, in the two words a client can act on. `immediately`
      # means the processor is billing the difference now; `period_end` means nothing
      # is carried forward and the move lands at the renewal.
      def plan_change(target, change)
        {
          "plan_id" => target.id,
          "effective" => change.timing.to_s,
          "proration" => change.proration_behavior
        }
      end

      # What the plan grants, and whether the subscription is granting it. A canceled
      # subscription grants nothing, which is the only answer here that is a decision
      # rather than a copy of the plan; a `past_due` or `unpaid` one still grants,
      # because the processor's grace period is a product decision and not this
      # service's to take away.
      def entitlements_for(subscription)
        entitlements = subscription.plan.entitlements
        granted = subscription.grants_entitlements?

        {
          "subscription_id" => subscription.id,
          "plan_id" => subscription.plan_id,
          "plan_slug" => subscription.plan.slug,
          "status" => subscription.status,
          "granted" => granted,
          "features" => granted ? Array(entitlements["features"]) : [],
          "limits" => granted ? (entitlements["limits"] || {}) : {}
        }
      end

      # The subscription, with its plan's price in integer minor units. The one wire
      # representation for an amount, and the same one everywhere it is returned —
      # `Plan#price` is a `Money` and `Money#to_h` is the crossing shape.
      def serialize(subscription)
        subscription.as_json.merge("price" => subscription.plan.price.to_h)
      end

      def refuse(code, field, message)
        @refusals << Refusal.new(code: code, field: field, message: message)
        nil
      end

      def refused?
        @refusals.any?
      end



      # One 422 or 409 for everything the request got wrong, in the order the
      # problems were found. A `:conflict` is 409 and carries no `errors[]`, because
      # the request was well-formed and simply collided — the same line
      # `render_validation_failure` draws.
      def render_refusals
        conflicts = @refusals.select { |refusal| refusal.code == :conflict }
        return render_problem(:conflict, detail: conflicts.map(&:message).join("; ")) if conflicts.any?

        render_problem(
          :validation_failed,
          detail: @refusals.map(&:message).join("; "),
          errors: @refusals.map(&:as_error)
        )
      end

      # The processor is not a cafaye client, and its refusals are its own business.
      # This service's own misconfiguration is a 503 — the caller's request was fine
      # and saying otherwise would send an operator looking in the wrong place — and
      # a processor refusal is a 422 about the plan, with the processor's message
      # logged and never returned to the caller.
      def refuse_processor(exception)
        log_processor_refusal(exception)

        case exception
        when Processor::StripeClient::Unconfigured
          render_problem(:unavailable, detail: "The payment processor is not configured.")
        else
          refuse(:validation_failed, "plan_id", "could not be applied by the payment processor")
        end
      end

      # A refusal this service reached on its own reasoning is not a processor
      # problem, and logging it as one would send an operator to the wrong system.
      def log_processor_refusal(exception)
        return if exception.is_a?(Subscriptions::PlanChange::Error) || exception.is_a?(Money::CurrencyMismatchError)

        Rails.logger.error("payment processor refused a request: #{exception.class}: #{exception.message}")
      end
  end
end
