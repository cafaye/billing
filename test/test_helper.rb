ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "openssl"

# Spec helpers. Plain modules, no framework gem.
Dir[Rails.root.join("test/support/**/*.rb")].sort.each { |file| require file }

# Fake collaborators for a single test.
#
# minitest 6 dropped `Object#stub` (it moved to the separate minitest-mock gem,
# which this service does not depend on), so we use the stub registry that
# ActiveSupport already keeps for time helpers. Stubs are also removed
# automatically in `after_teardown`; the block form below restores them sooner,
# so a failing assertion cannot leak a stub into the next test.
module StubbedCollaborators
  # Makes `ActiveRecord::Base.lease_connection` return `connection` for the
  # duration of the block. Used to simulate a database that is down.
  def with_lease_connection(connection)
    simple_stubs.stub_object(ActiveRecord::Base, :lease_connection) { connection }
    yield
  ensure
    simple_stubs.unstub_all!
  end

  # Sets environment variables for the duration of the block and puts the
  # previous values back, including "was not set at all". A `nil` value deletes
  # the key, which is how a test asks for "the secret is not configured".
  def with_env(variables)
    previous = variables.keys.to_h { |key| [ key, ENV[key] ] }
    variables.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

# Signs a webhook body the way Stripe signs one, so the suite exercises the real
# verification path instead of a stubbed one.
#
# The scheme is Stripe's, not ours: `t=<unix seconds>,v1=<hex>` where the HMAC is
# SHA-256 over "<timestamp>.<raw body>" keyed with the endpoint's signing secret.
# Fixtures are committed JSON; the secret below is a local constant that exists
# only in this suite and is a credential for nothing.
module StripeWebhookHelpers
  WEBHOOK_SECRET = "whsec_test_only_signing_secret"

  # The path in `openapi/v1.yaml` and in the routes. Duplicated here on purpose:
  # the integration test asserts the two agree, so a change to one without the
  # other fails instead of passing.
  STRIPE_WEBHOOK_PATH = "/v1/webhooks/stripe"

  def stripe_fixture(name)
    File.read(Rails.root.join("test/fixtures/stripe", "#{name}.json"))
  end

  def stripe_signature(payload, secret: WEBHOOK_SECRET, timestamp: Time.now.to_i)
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{payload}")
    "t=#{timestamp},v1=#{digest}"
  end

  # Posts a body to the Stripe webhook exactly as Stripe would: the raw bytes,
  # `application/json`, and a `Stripe-Signature` header over those bytes.
  #
  # The path is the literal documented path rather than the route helper, so
  # renaming the route cannot quietly leave these tests passing against a URL
  # that is no longer served.
  def post_stripe_webhook(payload, secret: WEBHOOK_SECRET, timestamp: Time.now.to_i, path: STRIPE_WEBHOOK_PATH)
    post path,
      params: payload,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "Stripe-Signature" => stripe_signature(payload, secret: secret, timestamp: timestamp)
      }
  end
end

# The Stripe signing secret for the suite. Set once, here, rather than in every
# test: it is a constant, not a secret, and the test that needs it *absent*
# deletes it with `with_env`.
ENV["STRIPE_WEBHOOK_SECRET"] = StripeWebhookHelpers::WEBHOOK_SECRET

module ActiveSupport
  class TestCase
    include StubbedCollaborators
    include StripeWebhookHelpers
    include TestSupport::FrozenClock
    include TestSupport::ApiHelpers

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
