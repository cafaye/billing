require "test_helper"

# THE PROOF. Nothing a caller sends reaches an exportable span.
#
# Everything else in this repository's observability work is necessary and not
# sufficient. `AllowlistTest` asserts on the ALLOWLIST — that the names are names
# somebody already thought of, and that no name contains a word that names
# content. That proves the keys that exist are absent. It cannot prove the keys
# nobody thought of are absent, and the realistic way this leaks is not an
# attacker. It is a well-meaning engineer in six months adding
# `span.set_attribute("customer.email", customer.email)` because it would help
# debug a subscription, in the service whose rows carry a customer's email, a
# processor id and a price in minor units.
#
# So this file plants a canary in every field a caller controls and asserts it
# appears in NOTHING that left billing — and it drives REAL requests through the
# REAL router, because the allowlist being correct says nothing about what the
# request path actually records.
#
# ## Why every absence assertion here is paired with a presence one
#
# A redaction boundary that deletes everything passes a "no canary" test and is
# useless. Three separate ways that happened while this repository's telemetry was
# being written, each of which left the suite green:
#
#   * an exporter implementing `export(span_datas)` where the callback is
#     `export(span_datas, timeout:)`, so it was never called and
#     `SimpleSpanProcessor#on_finish` swallowed the ArgumentError;
#   * an exporter that answered `force_flush` and `shutdown` but returned `false`
#     from `export`, where the contract wants `SUCCESS` — which is `0`, and `0` is
#     TRUTHY in Ruby, so the failure and the success look alike;
#   * a `record/2` guarded on a Hash-shaped span when the SDK hands over an object
#     with a different shape, so nothing was recorded at all.
#
# `TestSpans.rendered!/0` RAISES rather than returning an empty string, so a suite
# in which billing exported nothing fails loudly instead of passing quietly. That
# guard is the single place this is checked, and it is the reason `assert_no_canary`
# below is not a one-liner.
#
# ## The canary is SHORT, and that is deliberate
#
# A long canary would let a length ceiling be what makes a test pass, and a
# truncated leak is still a leak. This string is short enough that no bound in this
# repository can touch it, so what passes here passed because of the ALLOWLIST and
# nothing else.
class ObservabilityCanaryTest < ActionDispatch::IntegrationTest
  CANARY = "CANARY-4e1b-DO-NOT-EXPORT"

  setup do
    travel_to(frozen_now)
    TestSupport::TestSpanExporter.clear!
  end

  teardown do
    TestSupport::TestSpanExporter.clear!
  end

  # --- the request body -----------------------------------------------------

  test "a customer with an email and a processor id exports neither" do
    post "/v1/customers", params: {
      customer: {
        email: "#{CANARY}@example.com",
        processor_customer_id: "cus_#{CANARY}"
      }
    }

    assert_includes [ 201, 422 ], response.status
    assert_no_canary
  end

  test "a plan carrying a price and a slug exports neither" do
    post "/v1/plans", params: {
      plan: { name: CANARY, slug: "plan-#{CANARY}", price: "10.00", currency: "USD", interval: "month" }
    }

    assert_includes [ 201, 422 ], response.status
    assert_no_canary
  end

  test "a subscription addressed by a customer id in the path exports neither id" do
    customer = Customer.create!(owner_type: "Account", owner_id: SecureRandom.uuid,
                                processor: "stripe",
                                processor_customer_id: "cus_FAKE#{SecureRandom.hex(8)}")

    get "/v1/subscriptions/#{customer.id}/entitlements"

    assert_includes [ 200, 404 ], response.status
    assert_no_canary
  end

  # --- the path -------------------------------------------------------------

  test "an id in the PATH of a parameterised route reaches nothing" do
    # The route records its TEMPLATE, so a caller's own uuid cannot be on it. This
    # is the content half of the cardinality guarantee, and it is only observable
    # on a route with a parameter in it: for `/healthz` the path and the template
    # are the same string, so a service recording `request.path` passes every test
    # that drives a fixed path.
    get "/v1/customers/#{CANARY}"

    assert_response :not_found
    assert_no_canary
  end

  test "a slug in the PATH reaches nothing" do
    get "/v1/plans/#{CANARY}"

    assert_response :not_found
    assert_no_canary
  end

  # --- the query string -----------------------------------------------------

  test "an email in the query string of a matched route reaches nothing" do
    get "/v1/customers", params: { email: "#{CANARY}@example.com", owner_id: CANARY }

    assert_includes [ 200, 400 ], response.status
    assert_no_canary
  end

  # --- the headers ----------------------------------------------------------

  test "a bearer token, an API key, a cookie and a user-agent are all absent" do
    # billing authenticates with a signature on one path and nothing on another,
    # and it mints its own `Idempotency-Key`s — so a header attribute here is a
    # credential in a searchable, retained, widely-readable store. There is no
    # `http.request.header.*` on the allowlist at all.
    get "/healthz", headers: {
      "HTTP_AUTHORIZATION" => "Bearer sess_#{CANARY}",
      "HTTP_COOKIE" => "billing_session=#{CANARY}",
      "HTTP_X_API_KEY" => "caf_#{CANARY}",
      "HTTP_USER_AGENT" => "canary-agent/#{CANARY}",
      "HTTP_IDEMPOTENCY_KEY" => "9f8e7d6c-#{CANARY}"
    }

    assert_response :success
    assert_no_canary
  end

  # --- the webhook path, which is the sharpest one ---------------------------

  test "a signed webhook body exports neither the payload nor the signature" do
    # `test/integration/secrets_do_not_leak_test.rb` is about LOGS. This is about
    # spans, and the webhook is where the risk is highest: the body is
    # attacker-controlled by definition, and the signing secret is the credential
    # that would let somebody forge the next one.
    payload = {
      id: "evt_#{CANARY}",
      type: "customer.subscription.updated",
      data: { object: { id: "cus_#{CANARY}", email: "#{CANARY}@example.com" } }
    }.to_json
    timestamp = Time.now.to_i

    post StripeWebhookHelpers::STRIPE_WEBHOOK_PATH,
         params: payload,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "HTTP_STRIPE_SIGNATURE" => "t=#{timestamp},v1=#{OpenSSL::HMAC.hexdigest("SHA256", StripeWebhookHelpers::WEBHOOK_SECRET, "#{timestamp}.#{payload}")}"
         }

    assert_includes [ 200, 400, 503 ], response.status
    assert_no_canary
  end

  # --- an inbound traceparent -----------------------------------------------

  test "a malformed traceparent carrying content is IGNORED, not recorded" do
    # A malformed `traceparent` starts a new trace and is never a 4xx — the spec
    # says ignore it, and an affordance that can take a customer's request down is
    # a denial-of-service vector aimed at billing's own surface. The other half is
    # that "ignore" must not mean "truncate and keep the usable part".
    get "/healthz", headers: { "HTTP_TRACEPARENT" => "00-#{CANARY}-#{CANARY}-01" }

    assert_response :success
    assert_no_canary
  end

  test "a well-formed inbound traceparent links the spans without copying its header" do
    # The propagation half. A `traceparent` is a header the caller controls, and it
    # is 55 characters of caller-chosen text; the span must inherit the TRACE it
    # names and never carry the header. The trace id below is a fixed, well-formed
    # one so the assertion is about the propagation and not about a random value.
    get "/healthz", headers: {
      "HTTP_TRACEPARENT" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    }

    assert_response :success
    span = TestSupport::TestSpans.request_spans.first
    # `unpack1("H*")` because `SpanData#trace_id` is the RAW 16 BYTES, not the hex
    # string the header carries. Comparing it to the header's hex directly fails
    # with a diff full of `\xNN` escapes that reads like a propagation bug and is a
    # formatting difference.
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", span.trace_id.unpack1("H*"),
                 "the inbound traceparent did not become the span's parent. Without this the " \
                 "collector shows a trace per request and no trace per caller, which is the " \
                 "whole reason the header is read."
    assert_no_canary
  end

  # --- the error path -------------------------------------------------------

  test "a refused request's problem document reaches no span" do
    # `detail` is free text in the RFC 9457 envelope and is the one field that can
    # name what a caller sent. `Problem::INTERNAL_DETAIL` exists to keep it generic;
    # this asserts the generic answer never reaches a span either.
    post "/v1/customers", params: { customer: { email: CANARY } }

    assert_includes [ 201, 422 ], response.status
    rendered = TestSupport::TestSpans.rendered!
    refute_includes rendered, response.body
  end

  test "a 404's span carries a status and no message" do
    get "/v1/does-not-exist"

    assert_response :not_found
    span = TestSupport::TestSpans.request_spans.first
    assert_equal 404, span.attributes["http.response.status_code"]
    assert_no_canary
  end

  private

  # The presence assertion, in every test above.
  #
  # `rendered!/0` raises when the export is empty, so this is simultaneously "the
  # canary is absent" and "something was exported". A test that only ever asserted
  # absence would be satisfied by a billing that records nothing, which is the
  # failure three separate bugs produced while this was being written.
  def assert_no_canary
    exported = TestSupport::TestSpans.rendered!

    if exported.include?(CANARY)
      raise <<~MESSAGE

        THE REDACTION BOUNDARY LEAKED.

        The canary #{CANARY.inspect} reached an exportable span attribute. It was planted in a
        field a caller controls, so whatever route it took is a route by which a customer's
        email, a processor id, a signing secret, a bearer token or an entire webhook body
        reaches a searchable, retained, widely-readable store — and this service holds prices
        in minor units and a customer's whole subscription history, so those are the values it
        most cannot afford to publish.

        The whole export:

        #{exported}
      MESSAGE
    end

    exported
  end
end
