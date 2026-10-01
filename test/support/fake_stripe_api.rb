# A stand-in for the Stripe API, for the specs that have to make a request.
#
# It records what it was asked and returns a fixture of the processor's answer.
# The point is what the tests assert on: the *request*. A checkout URL and a
# subscription's existence both come from Stripe, so a test that invented them
# would be asserting its own invention; a test that records the request is
# asserting the thing this service is responsible for.
#
# It refuses exactly what Stripe refuses, so the error paths are real requests
# rather than a stubbed exception: a plan price that does not exist, and a
# subscription that does not.
class FakeStripeAPI
  # The processor's own ids, in the shapes the fixtures use.
  CheckoutSession = Data.define(:id, :url)
  Subscription = Data.define(:id, :status, :cancel_at_period_end)

  # Prices and subscriptions this fake knows about. Everything else is refused,
  # which is what makes "the processor said no" a thing the specs can arrange.
  #
  # The price list has to contain every price `StripeSubscriptionFixtures` hands
  # a plan, or a spec that puts a second plan on sale gets a processor refusal
  # where it meant a successful one. That is a second literal kept in step with
  # the first, and `test/support/fixture_processor_ids_test.rb` asserts the two
  # agree — the fake loads before the fixtures module, so the agreement cannot be
  # structural and is checked instead.
  KNOWN_PRICES = %w[
    price_1PZQaBcDeFgHiJkLmNoPqR2
    price_new
    price_FAKEteamplanBBBBBBBBB
    price_FAKElateralplanBBBBBBB
    price_FAKEcheaperplanBBBBBBB
    price_FAKEyearlyplanBBBBBBBB
  ].freeze
  KNOWN_SUBSCRIPTIONS = %w[sub_1PZQaBcDeFgHiJkLmNoPqR1].freeze

  # A refusal, in the processor's own vocabulary.
  #
  # The client rescues `Stripe::StripeError` because that is what the gem raises,
  # so the fake raises a subclass of it. That keeps the translation under test
  # honest: if the fake invented its own error class, the specs would pass while
  # the rescue clause in production went untouched.
  class StripeRefused < Stripe::StripeError; end

  attr_reader :requests

  def initialize
    @requests = []
    @sessions = 0
  end

  def create_checkout_session(params)
    @requests << params

    refuse_unknown_price(params[:line_items].first.fetch(:price))

    @sessions += 1
    id = format("cs_test_%014d", @sessions)
    CheckoutSession.new(id, "https://checkout.stripe.test/c/pay/#{id}")
  end

  def update_subscription(id, params)
    @requests << params.merge(id: id)

    refuse_unknown_price(params[:items].first) if params[:items]
    refuse_unknown_subscription(id)

    Subscription.new(id, "active", params[:cancel_at_period_end] == true)
  end

  def cancel_subscription(id, params)
    @requests << params.merge(id: id)

    refuse_unknown_subscription(id)

    Subscription.new(id, "canceled", false)
  end

  private
    def refuse_unknown_price(price)
      return if KNOWN_PRICES.include?(price)

      raise StripeRefused, "No such price: #{price}"
    end

    def refuse_unknown_subscription(id)
      return if KNOWN_SUBSCRIPTIONS.include?(id)

      raise StripeRefused, "No such subscription: #{id}"
    end
end
