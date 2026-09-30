# The local records a Stripe subscription fixture resolves to.
#
# A subscription event is only acted on when it can be attached to a cafaye
# customer and a cafaye plan — a subscription this service did not sell is not one
# it bills, and the delivery is recorded as `unknown_customer` / `unknown_plan`
# rather than matched to whoever shares an id. Every spec that ingests a
# subscription fixture therefore needs those two records, with the *processor's*
# ids on them, or the event is refused and the spec is asserting a refusal it did
# not mean to arrange.
#
# These helpers live here rather than in each spec so that the ids the fixtures
# carry and the ids the records answer to cannot drift apart in four places. The
# ids are the ones in the committed fixtures, so a fixture edited without its
# helpers failing is a fixture nobody looked at.
module StripeSubscriptionFixtures
  PROCESSOR_CUSTOMER_ID = "cus_R1pQKz9xLp2mN4vB6yH8jL0".freeze
  PROCESSOR_PRICE_ID = "price_1PZQaBcDeFgHiJkLmNoPqR2".freeze
  ACCOUNT_ID = "11111111-1111-4111-8111-111111111111".freeze

  # The cafaye customer a fixture's subscription belongs to. `account_owner_type`
  # is a parameter only so a spec can arrange the one case where a customer cannot
  # hold a subscription at all.
  def create_stripe_customer(account_id: ACCOUNT_ID, owner_type: "Account", processor_customer_id: PROCESSOR_CUSTOMER_ID)
    Customer.create!(
      owner_type: owner_type,
      owner_id: owner_type == "Account" ? account_id : SecureRandom.uuid,
      processor: "stripe",
      processor_customer_id: processor_customer_id
    )
  end

  def create_stripe_plan(price: Money.new(1900, "USD"), interval: "month", processor_price_id: PROCESSOR_PRICE_ID, slug: nil, name: nil)
    @stripe_plans ||= 0
    @stripe_plans += 1
    Plan.create!(
      name: name || "Pro #{@stripe_plans}",
      slug: slug || "pro-#{@stripe_plans}",
      price: price,
      interval: interval,
      processor_price_id: processor_price_id
    )
  end
end

module ActiveSupport
  class TestCase
    include StripeSubscriptionFixtures
  end
end
