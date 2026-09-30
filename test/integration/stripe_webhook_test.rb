require "test_helper"

# The HTTP edge. What a processor sees is the whole contract, and the rules it
# has to hold to are narrow:
#
#   * a valid signature is 200 — including a replay, an unknown type, a type we
#     deliberately ignore, and an event whose processing failed. Anything else
#     teaches the processor to retry something that will never succeed.
#   * a bad signature is 400 and stores nothing at all, because an unverified
#     body is not an event.
#   * a missing signing secret is our misconfiguration, not the sender's fault,
#     and must never be mistaken for a bad signature.
#
# The error bodies are the same `application/problem+json` every other non-2xx in
# this service is, from the same one place — asserted with the shared
# `assert_problem` helper rather than field by field.
class StripeWebhookTest < ActionDispatch::IntegrationTest
  setup do
    travel_to(frozen_now)
  end

  test "a signed event is accepted" do
    post_stripe_webhook(stripe_fixture("invoice.paid"))

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
  end

  test "a signed event emits exactly one internal event" do
    post_stripe_webhook(stripe_fixture("invoice.paid"))

    assert_equal 1, OutboxEvent.count
  end

  test "the endpoint is not wrapped in an HTML error page on failure" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_the_wrong_secret")

    assert_response :bad_request
    assert_equal "application/problem+json", response.media_type
  end

  test "a bad signature is rejected" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_the_wrong_secret")

    assert_response :bad_request
  end

  test "a bad signature stores nothing" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_the_wrong_secret")

    assert_equal 0, ProcessorWebhook.count
    assert_equal 0, OutboxEvent.count
  end

  test "a tampered body is rejected even when the signature was valid for the original" do
    original = stripe_fixture("invoice.paid")
    tampered = original.sub("\"amount_paid\": 8700", "\"amount_paid\": 87")

    post StripeWebhookHelpers::STRIPE_WEBHOOK_PATH, params: tampered,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "Stripe-Signature" => stripe_signature(original)
      }

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  test "a missing signature header is rejected" do
    post StripeWebhookHelpers::STRIPE_WEBHOOK_PATH, params: stripe_fixture("invoice.paid"), headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  # Stripe's tolerance window exists so a captured request cannot be replayed
  # tomorrow. Past the window the signature is refused even though the HMAC is
  # correct.
  test "a signature older than the tolerance window is rejected" do
    payload = stripe_fixture("invoice.paid")

    post_stripe_webhook(payload, timestamp: 10.minutes.ago.to_i)

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  test "a signature just inside the tolerance window is accepted" do
    payload = stripe_fixture("invoice.paid")

    post_stripe_webhook(payload, timestamp: 4.minutes.ago.to_i)

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
  end

  # Rotating an endpoint signing secret has a window where Stripe still signs
  # with the old one. Rather than a second variable, both are accepted here.
  test "a signature that verifies under either configured secret is accepted" do
    payload = stripe_fixture("invoice.paid")

    with_stripe_secrets("whsec_old_secret", "whsec_new_secret") do
      post_stripe_webhook(payload, secret: "whsec_old_secret")
    end

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
  end

  test "a signature that verifies under the second of two configured secrets is accepted" do
    payload = stripe_fixture("invoice.paid")

    with_stripe_secrets("whsec_old_secret", "whsec_new_secret") do
      post_stripe_webhook(payload, secret: "whsec_new_secret")
    end

    assert_response :ok
  end

  test "a signature that verifies under neither configured secret is rejected" do
    payload = stripe_fixture("invoice.paid")

    with_stripe_secrets("whsec_old_secret", "whsec_new_secret") do
      post_stripe_webhook(payload, secret: "whsec_some_other_secret")
    end

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  test "a single configured secret is accepted" do
    payload = stripe_fixture("invoice.paid")

    post_stripe_webhook(payload, secret: StripeWebhookHelpers::WEBHOOK_SECRET)

    assert_response :ok
  end

  # This is the failure mode the whole endpoint exists to prevent. 503, not 400:
  # the sender did nothing wrong, and telling them their signature is bad would
  # send them looking in the wrong place forever.
  test "an unconfigured signing secret is a server error, not a bad request" do
    with_env("STRIPE_WEBHOOK_SECRET" => nil) do
      post_stripe_webhook(stripe_fixture("invoice.paid"))
    end

    assert_response :service_unavailable
    assert_equal 0, ProcessorWebhook.count
  end

  test "an unconfigured signing secret is the same problem body as any other 503" do
    with_env("STRIPE_WEBHOOK_SECRET" => nil) do
      post_stripe_webhook(stripe_fixture("invoice.paid"))
    end

    assert_problem "unavailable"
  end

  test "an unconfigured signing secret never claims the signature was invalid" do
    with_env("STRIPE_WEBHOOK_SECRET" => nil) do
      post_stripe_webhook(stripe_fixture("invoice.paid"))
    end

    refute_equal "bad_request", response.parsed_body["code"]
  end

  test "an unconfigured signing secret is logged with its cause, and the body says nothing about it" do
    logged = with_env("STRIPE_WEBHOOK_SECRET" => nil) do
      capture_log { post_stripe_webhook(stripe_fixture("invoice.paid")) }
    end

    assert_includes logged, "SignaturesUnconfigured"
    assert_no_match(/whsec/, response.body)
  end

  test "a malformed body with a valid signature over it is rejected" do
    post_stripe_webhook("this is not json")

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  test "a replayed event is accepted and processed once" do
    payload = stripe_fixture("invoice.paid")

    post_stripe_webhook(payload)
    post_stripe_webhook(payload)

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
    assert_equal 1, OutboxEvent.count
  end

  test "a replayed subscription event emits one event, not two" do
    payload = stripe_fixture("customer.subscription.created")

    with_resolvable_subscription do
      post_stripe_webhook(payload)
      post_stripe_webhook(payload)
    end

    assert_equal 1, OutboxEvent.where(event_type: "billing.subscription.started").count
  end

  test "a replay carries the same response as the first delivery" do
    payload = stripe_fixture("invoice.paid")

    post_stripe_webhook(payload)
    first_status = response.status
    post_stripe_webhook(payload)

    assert_equal first_status, response.status
  end

  # Stripe does not promise ordering, and a webhook endpoint that assumed it would
  # reject a legitimate delivery. What changed in billing-04 is not the acceptance
  # — it is what a deletion arriving first now *does*.
  #
  # billing-03b normalized each event independently and published both, which left
  # an active subscription row for something the processor said was gone. An active
  # row grants entitlements. billing-04 keeps the deletion, as a canceled row that
  # grants nothing, and refuses the creation that follows it.
  test "a deletion arriving before its creation is accepted" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.deleted"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_response :ok
    assert_equal 2, ProcessorWebhook.where("type LIKE 'customer.subscription.%'").count
  end

  test "a deletion arriving before its creation leaves the subscription canceled" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.deleted"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_equal "canceled", Subscription.sole.status
    refute_predicate Subscription.sole, :grants_entitlements?
  end

  test "a deletion arriving before its creation is the only event, because nothing started" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.deleted"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_equal [ "billing.subscription.canceled" ], subscription_event_types
  end

  test "an update arriving before its creation is accepted" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.updated"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_response :ok
    assert_equal 2, ProcessorWebhook.where("type LIKE 'customer.subscription.%'").count
  end

  test "an update arriving before its creation records why it was refused" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.updated"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_equal "ignored:no_subscription_to_update", ProcessorWebhook.find_by(type: "customer.subscription.updated").error
  end

  # core: the event's `time` is when the state change happened, not when this
  # service read about it.
  test "each delivery keeps the time the processor reported" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
      travel_to 1.hour.from_now
      post_stripe_webhook(stripe_fixture("customer.subscription.deleted"))
    end

    started, canceled = OutboxEvent.where(event_type: SUBSCRIPTION_EVENTS).order(:created_at, :id).to_a

    assert_equal Time.utc(2026, 9, 30, 4, 0, 0), started.time
    assert_equal Time.utc(2026, 11, 14, 4, 0, 0), canceled.time
  end

  test "an unknown event type is accepted and stored" do
    post_stripe_webhook(stripe_fixture("charge.succeeded"))

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
    assert_equal "charge.succeeded", ProcessorWebhook.sole.type
  end

  test "an unknown event type emits nothing" do
    post_stripe_webhook(stripe_fixture("charge.succeeded"))

    assert_equal 0, OutboxEvent.count
  end

  test "a deliberately ignored event type is accepted" do
    post_stripe_webhook(stripe_fixture("ping"))

    assert_response :ok
  end

  test "a processor's own connectivity check is not treated as money" do
    post_stripe_webhook(stripe_fixture("ping"))

    assert_equal 0, OutboxEvent.count
  end

  # Stripe tells us about a subscription twice: once when the Checkout session
  # completes, once when the subscription itself is created. Emitting from both
  # would state one fact twice under two envelope ids, and a consumer counting
  # `billing.subscription.started` would count every Checkout signup twice.
  test "a subscription-mode checkout session is accepted and emits nothing" do
    post_stripe_webhook(stripe_fixture("checkout.session.completed"))

    assert_response :ok
    assert_equal 0, OutboxEvent.count
  end

  test "a subscription-mode checkout session records why it was ignored" do
    post_stripe_webhook(stripe_fixture("checkout.session.completed"))

    assert_equal "ignored:subscription_mode_is_restated_by_the_subscription_lifecycle", ProcessorWebhook.sole.error
  end

  test "a subscription signup states one fact once, not once per delivery channel" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("checkout.session.completed"))
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_equal [ "billing.subscription.started" ], subscription_event_types
  end

  # A signed body that is not an event cannot be stored: a row with no event id
  # could never be deduplicated and a row with no type could never be routed. It
  # is a 400 because that is the one case where the sender could not have known
  # — the signature is valid, so the bytes came from the holder of the secret, and
  # the bytes are still not an event.
  test "a signed body that is not JSON is rejected" do
    post_stripe_webhook("this is not json, but it is signed")

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  test "a signed body with no event type is rejected" do
    post_stripe_webhook({ "id" => "evt_untyped", "data" => { "object" => {} } }.to_json)

    assert_response :bad_request
    assert_equal 0, ProcessorWebhook.count
  end

  # The other half of the rule: a *well-formed* event whose mapping fails is
  # recorded and answered 200. It can be stored, it can never be fixed by a
  # retry, and a 5xx would only hide the parked row behind a timeout.
  test "an event whose mapping fails is answered 200, so the processor stops retrying" do
    post_stripe_webhook({ "id" => "evt_bare", "type" => "invoice.paid" }.to_json)

    assert_response :ok
    assert_equal 1, ProcessorWebhook.count
    assert_predicate ProcessorWebhook.sole.error, :present?
    assert_equal 0, OutboxEvent.count
  end

  test "a body signed but missing the fields an event needs is recorded as failed" do
    post_stripe_webhook({ "id" => "evt_bare", "type" => "invoice.paid" }.to_json)

    assert ProcessorWebhook.sole.error.start_with?("failed:"), "expected a parked row, got: #{ProcessorWebhook.sole.error.inspect}"
  end

  test "a failed event is logged with the processor event id, so the row is findable" do
    logged = capture_log { post_stripe_webhook({ "id" => "evt_logged", "type" => "invoice.paid" }.to_json) }

    assert_includes logged, "evt_logged"
  end

  test "the endpoint answers the same status for every signature failure" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_wrong")
    bad_signature_status = response.status
    post StripeWebhookHelpers::STRIPE_WEBHOOK_PATH, params: stripe_fixture("invoice.paid"), headers: { "CONTENT_TYPE" => "application/json" }
    missing_signature_status = response.status

    assert_equal bad_signature_status, missing_signature_status
  end

  test "a rejected signature answers with this service's problem body" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_wrong")

    assert_problem "bad_request"
  end

  test "a rejected signature's body distinguishes a bad signature from a body that is not an event" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_wrong")
    bad_signature_detail = json_body["detail"]

    post_stripe_webhook("this is not json, but it is signed")
    malformed_detail = json_body["detail"]

    assert_not_equal bad_signature_detail, malformed_detail
  end

  test "a rejection is logged with its cause, so an operator can tell the two apart" do
    logged = capture_log { post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_wrong") }

    assert_includes logged, "UnverifiedSignature"
  end

  test "an error body carries a trace id, so support can start from it" do
    post_stripe_webhook(stripe_fixture("invoice.paid"), secret: "whsec_wrong")

    assert_predicate response.parsed_body["trace_id"].to_s, :present?
  end

  # Fixture name to the cafaye event type it must produce. The fixture name is a
  # label; the event's own `type` inside it is what the service routes on, and
  # `checkout.session.completed` appears twice because the mode in the payload
  # decides what the session means.
  HANDLED_TYPES = {
    "invoice.paid" => "billing.payment.succeeded",
    "invoice.payment_failed" => "billing.payment.failed",
    "checkout.session.completed.payment" => "billing.payment.succeeded"
  }.freeze

  HANDLED_TYPES.each do |fixture, event_type|
    test "#{fixture} emits #{event_type}" do
      post_stripe_webhook(stripe_fixture(fixture))

      assert_response :ok
      assert_equal event_type, OutboxEvent.sole.event_type
    end
  end

  # A subscription delivery has to resolve to a customer and a plan before it is
  # acted on, so it is asserted on its own rather than in the table above: those
  # specs assert on `OutboxEvent.sole`, and the two records this one needs publish
  # events of their own.
  test "customer.subscription.created emits billing.subscription.started" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
    end

    assert_response :ok
    assert_equal [ "billing.subscription.started" ], subscription_event_types
  end

  # The three subscription types, each following from the state the delivery put the
  # row into. Asserted as one sequence because the point is that the *state* decides
  # the type: a delivery is an update or a cancellation depending on what the row
  # was, and a start or a cancellation depending on whether the row existed.
  test "a subscription is started, updated and then canceled, in that order" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
      travel_to 1.hour.from_now
      post_stripe_webhook(stripe_fixture("customer.subscription.updated"))
      travel_to 2.hours.from_now
      post_stripe_webhook(stripe_fixture("customer.subscription.deleted"))
    end

    assert_equal(
      [ "billing.subscription.started", "billing.subscription.updated", "billing.subscription.canceled" ],
      subscription_event_types
    )
  end

  test "every subscription event is correlated on this service's own subscription" do
    with_resolvable_subscription do
      post_stripe_webhook(stripe_fixture("customer.subscription.created"))
      travel_to 1.hour.from_now
      post_stripe_webhook(stripe_fixture("customer.subscription.updated"))
    end

    assert_equal [ Subscription.sole.id ], OutboxEvent.where(event_type: SUBSCRIPTION_EVENTS).pluck(:subject).uniq
  end

  SUBSCRIPTION_EVENTS = %w[
    billing.subscription.started
    billing.subscription.updated
    billing.subscription.canceled
  ].freeze

  def subscription_event_types
    OutboxEvent.where(event_type: SUBSCRIPTION_EVENTS).order(:created_at, :id).pluck(:event_type)
  end

  # An event type the outbox's closed list does not hold would park every
  # delivery as a failure and still answer 200 — a silent outage, discovered by
  # Stripe's dashboard rather than here.
  test "every type this endpoint can emit is one the outbox has declared" do
    assert_empty HANDLED_TYPES.values.uniq - OutboxEvent::TYPES
  end

  test "every handled type lands in the manifest's events list" do
    manifest_events = YAML.load_file(Rails.root.join("cafaye.yml")).dig("exposes", "events")

    assert_empty HANDLED_TYPES.values.uniq - manifest_events
  end

  test "the endpoint is served at the path the OpenAPI document declares" do
    document = YAML.load_file(Rails.root.join("openapi/v1.yaml"))

    assert_includes document.fetch("paths").keys, StripeWebhookHelpers::STRIPE_WEBHOOK_PATH
  end

  test "the manifest points at the OpenAPI document that declares the endpoint" do
    manifest = YAML.load_file(Rails.root.join("cafaye.yml"))

    assert_equal "openapi/v1.yaml", manifest.dig("exposes", "api")
  end

  test "the endpoint is served" do
    post_stripe_webhook(stripe_fixture("invoice.paid"))

    assert_response :ok
  end

  test "the health probes are unaffected by the webhook surface" do
    get "/healthz"

    assert_response :ok
  end

  private
    def with_stripe_secrets(*secrets)
      with_env("STRIPE_WEBHOOK_SECRETS" => secrets.join(",")) { yield }
    end

    # The cafaye customer and plan a subscription fixture resolves to.
    #
    # A subscription event is acted on only when it can be attached to both — this
    # service does not bill a subscription it did not sell — so a spec that posts
    # one has to arrange them. Called from the spec rather than from `setup`
    # because creating a customer and a plan publishes two events of their own,
    # and the specs about payments assert on `OutboxEvent.sole`.
    def with_resolvable_subscription
      create_stripe_customer
      create_stripe_plan
      yield
    end
end
