require "test_helper"

# The allowlist, asserted on directly.
#
# `CanaryTest` proves no caller-supplied content reaches an exportable span. This
# file proves the ALLOWLIST is the thing doing the work, and the two are not the
# same claim: a canary test is satisfied by a service that exports nothing, and an
# allowlist test is satisfied by a service that never calls `record/2`. Both are
# needed, and each says which failure it catches.
#
# The pattern is the fleet's, promoted: the realistic way billing's redaction
# boundary fails is not an attacker. It is a well-meaning engineer in six months
# adding `span.set_attribute("customer.email", customer.email)` because it would
# help debug a subscription, in the one service in the fleet whose rows carry a
# customer's email, a processor id and a price in minor units. So the LIST itself is
# the assertion, and the words it may not contain are written down.
class ObservabilityAllowlistTest < ActiveSupport::TestCase
  # Words that name content rather than shape. A span attribute named for one of
  # them is a span attribute somebody will eventually fill with the thing it names,
  # and the allowlist is the only thing standing between that intention and a
  # searchable, retained, widely-readable store.
  #
  # `customer` and `account` are here even though billing's own vocabulary is full
  # of them, because the argument is about the ATTRIBUTE NAME, not the domain: a
  # `customer.id` on a span is a tenant key on a measurement, and that is
  # unbounded cardinality under a different name.
  FORBIDDEN_WORDS = %w[
    prompt message content text body header query params parameter payload
    email subject recipient recipient_id customer user account tenant owner
    secret token credential authorization cookie api_key signature
    price amount currency minor_units invoice
    detail exception stacktrace sql
  ].freeze

  test "no allowed name contains a word that names content" do
    offenders = Kit::Telemetry::ALLOWED_SPAN_ATTRIBUTES.select do |name|
      lowered = name.downcase
      FORBIDDEN_WORDS.any? { |word| lowered.include?(word) }
    end

    assert_empty offenders,
                 "the span-attribute allowlist carries names that could hold content: #{offenders.inspect}.\n\n" \
                 "This list is the redaction boundary. A name that names content is a name " \
                 "somebody will fill with the thing it names, and nothing downstream can " \
                 "strip it: `Kit::Telemetry.record/2` is the only recorder, so a name that " \
                 "gets in here gets exported."
  end

  test "the allowlist is frozen" do
    assert_predicate Kit::Telemetry::ALLOWED_SPAN_ATTRIBUTES, :frozen?,
                     "a mutable allowlist is a list something can add to at runtime, in a " \
                     "process that has already decided what it may export"
  end

  test "every allowed name is a semantic convention this service can actually set" do
    # The positive direction, and it is here because the negative direction above
    # would pass against an empty list: a boundary that allows nothing exports
    # nothing, which is indistinguishable from a boundary that refuses everything
    # until somebody tries to record something.
    assert_equal %w[http.request.method http.response.status_code http.route error.type].sort,
                 Kit::Telemetry::ALLOWED_SPAN_ATTRIBUTES.sort
  end

  test "a name that is not on the list is DROPPED, not recorded" do
    span = FakeSpan.new

    Kit::Telemetry.record(span, { "customer.email" => "someone@example.com" })

    assert_empty span.attributes,
                 "record/2 recorded an attribute that is not on the allowlist. That function " \
                 "is the boundary; a name it accepts is a name that leaves the process."
  end

  test "a name on the list IS recorded" do
    span = FakeSpan.new

    Kit::Telemetry.record(span, { "http.route" => "/v1/customers/:id" })

    assert_equal({ "http.route" => "/v1/customers/:id" }, span.attributes)
  end

  test "a symbol key is recorded when its NAME is allowed, and dropped when it is not" do
    # The two directions in one test, because a matcher that only handled strings
    # would refuse every symbol and pass the second half silently: nothing in
    # production writes a symbol key today, so a test that only asserted the drop
    # would be satisfied by a recorder that dropped everything.
    span = FakeSpan.new

    Kit::Telemetry.record(span, { "http.request.method": "GET", customer_email: "someone@example.com" })

    assert_equal({ "http.request.method" => "GET" }, span.attributes)
  end

  test "a nil value is dropped even when the name is allowed" do
    # `error.type` is nil on every non-5xx request, and a nil attribute is a key
    # present with no value — which a metric exporter turns into a series with an
    # empty label rather than no series at all.
    span = FakeSpan.new

    Kit::Telemetry.record(span, { "error.type" => nil })

    assert_empty span.attributes
  end

  test "a nil span and nil attributes are both no-ops" do
    assert_nil Kit::Telemetry.record(nil, { "http.route" => "/v1/plans" })

    span = FakeSpan.new
    assert_same span, Kit::Telemetry.record(span, nil)
    assert_empty span.attributes
  end

  test "a value that is a whole customer record is refused by the NAME, not by its shape" do
    # The refusal has to be by name. A check on the value's class would be a
    # second, weaker rule that a `to_s` defeats, and it would have to be
    # maintained as carefully as the name list — which is how a boundary grows two
    # halves and one of them rots.
    span = FakeSpan.new
    customer = Struct.new(:email, :processor_customer_id, keyword_init: true).new(
      email: "someone@example.com", processor_customer_id: "cus_123"
    )

    Kit::Telemetry.record(span, { "http.route" => "/v1/customers", "billing.customer" => customer })

    assert_equal({ "http.route" => "/v1/customers" }, span.attributes)
  end

  test "error.type is a CLOSED vocabulary, and a value outside it is not recorded" do
    span = FakeSpan.new

    Kit::Telemetry.record(span, { "error.type" => "PG::ConnectionBad" })

    assert_empty span.attributes,
                 "an exception class name became a span attribute. That is unbounded " \
                 "cardinality from a library's own naming, and it is the reason " \
                 "Kit::Telemetry::ERROR_TYPES exists."
  end

  test "every value Kit::Telemetry can produce for error.type is on the closed list" do
    produced = [
      Kit::Telemetry.error_type(RuntimeError.new("boom"), :unhandled),
      Kit::Telemetry.error_type(StandardError.new, :routing),
      Kit::Telemetry.error_type(StandardError.new, :middleware)
    ].compact

    assert_equal Kit::Telemetry::ERROR_TYPES.sort, produced.sort,
                 "error_type/2 produced a value that is not in the closed vocabulary. Either " \
                 "the vocabulary or the function has drifted, and a label that is not in the " \
                 "closed list is one more series per exception class."
  end

  test "error_type returns nil for a value it does not recognise" do
    # nil rather than a guess: the span still carries the status, so the failure is
    # visible. What it will not carry is a new label for every exception class the
    # standard library happens to have.
    assert_nil Kit::Telemetry.error_type(nil, :something_new)
    assert_nil Kit::Telemetry.error_type("not even an exception", :unhandled)
  end

  # A span that records what it was told, and nothing else. The real SDK's Span is
  # used everywhere else; this exists so the DROPS above assert on the argument
  # `record/2` computed rather than on what the SDK decided to keep.
  class FakeSpan
    attr_reader :attributes

    def initialize
      @attributes = {}
    end

    def set_attribute(name, value)
      @attributes[name] = value
    end
  end
end
