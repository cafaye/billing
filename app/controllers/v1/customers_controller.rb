module V1
  # /v1/customers — the billing-side record of something identity knows about.
  #
  # Open in v0: there is no authorization on this controller, and that is a
  # recorded gap rather than a decision (README, "Authorization"). Without a
  # token there is no account to scope a query by, so `index` returns every
  # customer. The day the platform's authorization packet lands this controller
  # needs a scope it does not have today, and that is a breaking change to
  # this surface rather than a bug fix.
  class CustomersController < BaseController
    def index
      render_page(paginate(Customer.all), ->(customer) { customer.as_json })
    end

    def show
      render json: customer_record, status: :ok
    end

    def create
      replayed = replayed_response
      return render_replayed_response(replayed) if replayed

      customer = Customer.new(customer_params)

      if customer.save
        render json: customer, status: :created, location: "/v1/customers/#{customer.id}"
        remember_response(customer.as_json)
      else
        render_validation_failure(customer)
      end
    end

    def update
      customer = customer_record
      customer.assign_attributes(customer_params)

      if customer.save
        render json: customer, status: :ok
      else
        render_validation_failure(customer)
      end
    end

    private
      def customer_record
        @customer_record ||= Customer.find(uuid_param!(params[:id]))
      end

      # A fixed attribute list rather than the whole body: an unrecognised field
      # is not an error here, it is a field this version does not have, and
      # letting it through would mean `owner_type` could be rewritten by a
      # request that only meant to change an email address.
      def customer_params
        params.permit(:owner_type, :owner_id, :processor, :processor_customer_id, :email, metadata: {})
      end
  end
end
