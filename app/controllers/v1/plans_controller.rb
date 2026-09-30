module V1
  # /v1/plans — what can be bought, at what price, on what cadence.
  #
  # The addressing is deliberately asymmetric, and it is the packet's shape
  # rather than an oversight: `GET /v1/plans/:slug` reads a plan by the handle
  # that appears in a URL a human or a pricing page would use, while
  # `PATCH /v1/plans/:id` writes by the uuid, because a slug can be changed by
  # the very request being made and a mutable handle is not a safe thing to
  # address a mutation by. Both are 404 for the other's identifier, and the
  # specs say so.
  #
  # Open in v0, same as CustomersController, and for the same reason.
  class PlansController < BaseController
    def index
      render_page(paginate(Plan.all), ->(plan) { plan.as_json })
    end

    def show
      render json: Plan.find_by!(slug: params[:slug]), status: :ok
    end

    def create
      replayed = replayed_response
      return render_replayed_response(replayed) if replayed

      plan = Plan.new(plan_params)
      failures = assign_price(plan, params[:price])

      # `plan.save` first, deliberately: it is what populates the model's own
      # errors, and short-circuiting on the price failure first would report one
      # problem to a client who sent three.
      if plan.save && failures.empty?
        render json: plan, status: :created, location: "/v1/plans/#{plan.id}"
        remember_response(plan.as_json)
      else
        render_price_failure(plan, failures)
      end
    end

    def update
      plan = plan_record
      plan.assign_attributes(plan_params)
      # A PATCH that does not mention a price must not touch one, so the price
      # is only read when the key is present at all.
      failures = params.key?(:price) ? assign_price(plan, params[:price]) : []

      if plan.save && failures.empty?
        render json: plan, status: :ok
      else
        render_price_failure(plan, failures)
      end
    end

    private
      # The two columns a price is stored in. The client never sends either — it
      # sends `price` — so this is how one amount problem is reported once, under
      # the name the caller used.
      PRICE_COLUMNS = %i[amount_cents currency].freeze

      def plan_record
        Plan.find(uuid_param!(params[:id]))
      end

      def plan_params
        params.permit(:name, :slug, :processor_product_id, :processor_price_id, :interval, :trial_days, :active)
      end

      # The price is not permitted with the rest, because it is not a column —
      # it is two columns that only `price=` may write, and the only value that
      # may be written is a Money.
      def assign_price(plan, price)
        money, error = MoneyParams.parse(price)
        return [ ProblemResponses::Failure.new(field: "price", code: "invalid_format", message: "price #{error}") ] if error

        # The only path by which an amount reaches this model. `price=` refuses
        # anything that is not a Money, so a plan can never hold a bare integer
        # that has lost its currency.
        plan.price = money
        []
      end

      def render_price_failure(plan, param_failures)
        if param_failures.any?
          # The price was refused before it became an amount, so the two columns
          # it would have been stored in are simply empty. Reporting them as well
          # would say the same thing a second time under two other names.
          render_validation_failure(plan, param_failures, except: PRICE_COLUMNS)
        else
          # The price became an amount, and the model is refusing *that* — a
          # negative one, a currency that survived normalisation but not the
          # shape. It is still a problem with the price the client sent.
          render_validation_failure(plan, rename: PRICE_COLUMNS.to_h { |column| [ column, "price" ] })
        end
      end
  end
end
