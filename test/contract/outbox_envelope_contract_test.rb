require "test_helper"

# Contract test against core's frozen event envelope schema.
#
# PLAN.md §3: "Contract tests pass against the `core` specs for every
# API/event touched." This is that test for the three events billing-02 emits.
#
# It reads core's real schema rather than restating it, so a change in core is
# caught here instead of being discovered by a consumer's SDK. When core is not
# on disk — a standalone service checkout, where `core` is a different
# repository — the test skips and says so rather than passing vacuously.
class OutboxEnvelopeContractTest < ActiveSupport::TestCase
  ENVELOPE_SCHEMA = "schemas/event-envelope.schema.json"
  MANIFEST = "cafaye.yml"

  # Events this service publishes that core's catalog has no row for. The packet
  # asks for a plan-update event and core's catalog is a different repository,
  # so the row is an action item there, not something this worktree can land.
  # See the DECISION NEEDED in cafaye.yml. This list is the mechanical half of
  # that obligation: core's own suite only checks core's example manifests, and
  # `caf contract lint` does not exist yet, so without this a new event type
  # published here with no catalog row would pass every suite in the system.
  PENDING_CORE_CATALOG_ROWS = %w[billing.plan.updated].freeze

  # Events whose `data` does not yet satisfy core's payload schema, and exactly
  # how it differs. **Empty in billing-04.**
  #
  # billing-03b recorded a large gap here: core's
  # `schemas/events/billing/subscription/started.schema.json` names eight fields
  # and is closed with `additionalProperties: false`, while that build sent eleven
  # fields of its own and was missing two of core's. Two changes closed almost all
  # of it, and both are real work rather than a change of assertion:
  #
  #   * the subscriptions table landed, so `plan_id` and `account_id` are now
  #     carried from a real plan and a real account rather than absent;
  #   * a `billing.subscription.started` event is now built to core's shape — its
  #     eight fields and nothing else — so the processor's provenance stayed out of
  #     a payload core's schema rejects.
  #
  # What is *not* closed is the id format, and that is recorded below instead, in
  # `PENDING_ID_PATTERNS`, because it is a different kind of debt: the fields and
  # their types now match, and what is left is that this service's ids are uuids
  # where core asks for `sub_`/`pln_`/`acc_` prefixed ULIDs. That is an id scheme
  # for the platform to decide, not something a worktree can change.
  #
  # Asserted as a set rather than subtracted from the failures. Subtracting would
  # let a payload that starts matching sit here forever, and would let a new event
  # stop matching without anyone noticing. A set means a difference in either
  # direction fails.
  PENDING_PAYLOAD_ALIGNMENT = {}.freeze

  # core's pattern for each id in its started payload, and the reason this service
  # does not meet it yet.
  #
  # This is the one disagreement left with core's schema, so it is asserted in both
  # directions: the pattern core declares must be the one recorded here, and the
  # value this service emits must *not* match it. A payload that starts matching
  # fails, which is how the entry gets removed rather than forgotten.
  PENDING_ID_PATTERNS = {
    "billing.subscription.started" => {
      "subscription_id" => /\Asub_[0-9A-Z]{26}\z/,
      "plan_id" => /\Apln_[0-9A-Z]{26}\z/,
      "account_id" => /\Aacc_[0-9A-Z]{26}\z/
    }
  }.freeze

  # The events core has no payload schema for, which core's outbox checklist asks
  # for. This is the accounting, and it fails the day core lands one so the entry
  # is dropped deliberately rather than by accident.
  NO_PAYLOAD_SCHEMA_YET = (OutboxEvent::TYPES - PENDING_PAYLOAD_ALIGNMENT.keys - PENDING_ID_PATTERNS.keys).freeze

  # The webhook fixtures that produce the events that do not come from a model
  # callback. Ingested for real by the fixtures under test, so the payloads
  # checked against core are the ones this build would put on the wire.
  WEBHOOK_FIXTURES = %w[
    customer.subscription.created
    customer.subscription.updated
    customer.subscription.deleted
    invoice.paid
    invoice.payment_failed
    checkout.session.completed.payment
  ].freeze

  setup do
    skip("core is not on disk; set CORE_PATH to #{default_core_path}") unless schema
    travel_to(frozen_now)
  end

  test "every event billing emits satisfies core's envelope schema" do
    envelopes.each do |envelope|
      assert_valid_envelope(envelope)
    end
  end

  test "the event type pattern this service validates against is core's" do
    assert_same_grammar schema.fetch("$defs").dig("eventType", "pattern"), OutboxEvent::TYPE_PATTERN
  end

  test "the subject pattern this service validates against is core's" do
    assert_same_grammar schema.fetch("properties").dig("subject", "pattern"), OutboxEvent::SUBJECT_PATTERN
  end

  test "an event type is anchored to the whole string, not to a line of one" do
    # core's JSON Schema pattern is written with `^` and `$`, which in a Ruby
    # Regexp anchor to a line rather than to the string. This service anchors
    # with `\A` and `\z`, which is strictly narrower: an envelope can never be
    # smuggled through by appending a second line. Narrower is the safe
    # direction, so the difference is asserted rather than papered over.
    assert_not OutboxEvent::TYPE_PATTERN.match?("billing.plan.created\nrm -rf /")
    assert_not OutboxEvent::SUBJECT_PATTERN.match?("cus_1\ntrace_id: x")
  end

  test "the source is the service name, which is what core requires of it" do
    assert_equal manifest.fetch("name"), "billing"
    envelopes.each { |envelope| assert_equal "billing", envelope.fetch("source") }
  end

  test "every type in the manifest is a type this service can emit" do
    assert_equal manifest.fetch("exposes").fetch("events").sort, OutboxEvent::TYPES.sort
  end

  test "every type this service emits has a catalog row in core" do
    catalog = core_catalog

    skip("core's catalog could not be read") if catalog.nil?

    undeclared = OutboxEvent::TYPES - catalog

    # Subtract the known debt rather than skipping: a *new* type published
    # without a catalog row still fails here, and when core lands the row the
    # difference stays empty with nothing to clean up.
    assert_empty undeclared - PENDING_CORE_CATALOG_ROWS,
      "core's catalog has no row for these, and nothing is tracking that: #{undeclared.inspect}"
  end

  test "every event payload matches core's payload schema, where one exists" do
    # core v0.2 (D3) put the payload schemas in core and the outbox checklist
    # asks for `data` to be validated against
    # `schemas/events/<service>/<entity>/<action>.schema.json` before the insert.
    # One of the two core ships is billing's, so this stops being bookkeeping the
    # moment it lands for a type this build publishes.
    assert_equal PENDING_PAYLOAD_ALIGNMENT, payload_mismatches,
      "the payloads that do not match core's schemas have changed: fix them, or record the new gap in PENDING_PAYLOAD_ALIGNMENT and in cafaye.yml"
  end

  # The one disagreement left with core's started schema: the three ids.
  #
  # core asks for `sub_`/`pln_`/`acc_` prefixed ULIDs. This service's ids are
  # uuids — `Plan#id` and `Customer#owner_id` have been uuids since billing-02, and
  # changing the id scheme of a published API is a breaking change to a contract
  # several services already read. So the fields are present and correctly typed,
  # and the *format* is a decision for whoever owns the platform's id scheme.
  #
  # Asserted in both directions: the pattern core declares must be the one recorded,
  # and the value emitted must not match it. A payload that starts matching fails,
  # which is how the entry is removed rather than forgotten.
  PENDING_ID_PATTERN_TEST = "every pending id pattern is still core's, and our ids still miss it"

  # The corpus the patterns are compared over. Behaviour, not text: the same
  # grammar is the same *set of accepted strings*, and `Regexp#source` is not a
  # reliable way to read one back — Ruby rewrites a pattern's source depending on
  # the encoding it was compiled in, so comparing texts passes once and fails
  # forever after with nothing changed in between. `assert_same_grammar` below is
  # the same technique the envelope patterns use, for the same reason.
  ID_PATTERN_CORPUS = [
    "sub_01J9Z8QK5M4N7P2R3T6V8W9X0A",
    "pln_01J9Z8QK5M4N7P2R3T6V8W9X0A",
    "acc_01J9Z8QK5M4N7P2R3T6V8W9X0A",
    # What this service actually emits: a uuid.
    "0198f1c2-7a41-7c3b-9d55-2f0b6a1e4c88",
    "11111111-1111-4111-8111-111111111111",
    # Neighbouring shapes, where a difference in the pattern would show up.
    "sub_01j9z8qk5m4n7p2r3t6v8w9x0a",
    "sub_01J9Z8QK5M4N7P2R3T6V8W9X0",
    "sub_01J9Z8QK5M4N7P2R3T6V8W9X0AB",
    "sub_",
    "sub",
    "pln_",
    "acc_",
    "customer_01J9Z8QK5M4N7P2R3T6V8W9X0A",
    "usub_01J9Z8QK5M4N7P2R3T6V8W9X0A"
  ].freeze

  test PENDING_ID_PATTERN_TEST do
    PENDING_ID_PATTERNS.each do |event_type, fields|
      data = data_for(event_type)
      properties = payload_schema_for(event_type).fetch("properties")

      fields.each do |field, pattern|
        core_pattern = properties.fetch(field).fetch("pattern")

        assert_same_grammar core_pattern, pattern, ID_PATTERN_CORPUS

        assert_not pattern.match?(data.fetch(field)),
          "#{event_type}.#{field} now matches core's pattern, so the gap is closed: drop it from PENDING_ID_PATTERNS"
      end
    end
  end

  # core's patterns are written with `^` and `$`, which in a Ruby `Regexp` anchor
  # to a *line* rather than to the string, while this service's anchor the whole
  # string with `\A` and `\z`. The difference is asserted rather than papered over:
  # ours is strictly narrower, so an id can never be smuggled through by appending a
  # second line, and comparing the two on a corpus containing one is meaningless
  # without saying so.
  test "our id patterns are anchored to the whole string, where core's are anchored to a line" do
    PENDING_ID_PATTERNS.each do |event_type, fields|
      properties = payload_schema_for(event_type).fetch("properties")

      fields.each do |field, pattern|
        assert_not pattern.match?("sub_01J9Z8QK5M4N7P2R3T6V8W9X0A\nsub_forged"),
          "#{event_type}.#{field} accepts a second line, which core's pattern would"
        assert_equal properties.fetch(field).fetch("pattern").start_with?("^"), true,
          "core's pattern for #{event_type}.#{field} is no longer anchored with ^: re-read the schema"
      end
    end
  end

  test "the corpus would notice a pattern that had changed" do
    # The corpus is only evidence about the strings in it, so it is checked against
    # a pattern that is deliberately different — here, one that wants a different
    # length. Without this, a corpus of strings every plausible pattern accepts
    # would compare equal to anything and the assertion above would be decorative.
    changed = Regexp.new("^pln_[0-9A-Z]{25}$")
    ours = PENDING_ID_PATTERNS.fetch("billing.subscription.started").fetch("plan_id")

    disagreements = ID_PATTERN_CORPUS.reject { |candidate| changed.match?(candidate) == ours.match?(candidate) }

    assert_not_empty disagreements, "the corpus cannot tell two different id patterns apart"
  end

  test "the set of events with an id-pattern gap has changed" do
    with_schema = OutboxEvent::TYPES.select { |event_type| payload_schema_for(event_type)&.dig("properties") }

    assert_equal PENDING_ID_PATTERNS.keys.sort, with_schema.sort,
      "the set of events checked for an id-format gap has changed: update PENDING_ID_PATTERNS and the reason in cafaye.yml"
  end

  test "the set of events with no payload schema in core has changed" do
    unspecified = OutboxEvent::TYPES.reject { |event_type| payload_schema_for(event_type) }

    assert_equal NO_PAYLOAD_SCHEMA_YET.sort, unspecified.sort,
      "the set of events with no payload schema in core has changed: drop the entries this service no longer owes one for"
  end

  # A type with no fixture here would be silently unchecked by the test above,
  # which is the failure mode a contract test exists to prevent.
  test "the events under test are every type this service publishes" do
    assert_equal OutboxEvent::TYPES.sort, envelopes.map { |envelope| envelope.fetch("type") }.uniq.sort
  end

  test "the manifest declares an api, and the document it points at exists" do
    api = manifest.fetch("exposes").fetch("api")

    assert_path_exists Rails.root.join(api)
  end

  private
    # --- the fixtures under test: real emissions, not hand-built envelopes ---

    def envelopes
      @envelopes ||= emit_one_event_of_every_type
    end

    # Three of the eight events come from a model callback and five from the
    # webhook mapping. Both are produced here the way production produces them —
    # a record written, a signed fixture ingested — because an envelope assembled
    # by hand in a test is an envelope nothing has checked this service against.
    # A subscription delivery is acted on only when it resolves to a cafaye customer
    # and a cafaye plan, so the customer and the plan here carry the *processor's*
    # ids the fixtures use. Without them the three subscription fixtures would be
    # refused and there would be no subscription envelope to check against core.
    def emit_one_event_of_every_type
      # Account-owned, not user-owned, and that is load-bearing: a subscription is
      # billed to an account, and the lifecycle refuses to attach one to a customer
      # that belongs to a user — which account a user belongs to is identity's fact
      # and no event carrying it is in this build's `consumes`.
      Customer.create!(
        owner_type: "Account",
        owner_id: "11111111-1111-4111-8111-111111111111",
        processor: "stripe",
        processor_customer_id: StripeSubscriptionFixtures::PROCESSOR_CUSTOMER_ID
      )
      plan = Plan.create!(
        name: "Pro monthly",
        slug: "pro-monthly",
        price: Money.new(1900, "USD"),
        interval: "month",
        processor_price_id: StripeSubscriptionFixtures::PROCESSOR_PRICE_ID
      )
      plan.update!(active: false)

      WEBHOOK_FIXTURES.each { |fixture| ingest(fixture) }

      OutboxEvent.order(:created_at, :id).map(&:to_envelope)
    end

    def ingest(fixture)
      body = JSON.parse(stripe_fixture(fixture))

      Webhooks::Ingestion.new(processor: :stripe, event_id: body["id"], type: body["type"], payload: body).call
    end

    def data_for(event_type)
      envelopes.find { |envelope| envelope.fetch("type") == event_type }.fetch("data")
    end

    # Every way a payload disagrees with a core schema, as a hash keyed by
    # event type, so a difference in either direction fails. An empty result is
    # the passing case; anything in it that is not recorded above is a contract
    # breach, not a tolerance.
    def payload_mismatches
      OutboxEvent::TYPES.each_with_object({}) do |event_type, mismatches|
        schema = payload_schema_for(event_type)
        next if schema.nil?

        data = data_for(event_type)
        properties = schema.fetch("properties")

        difference = {
          missing: (schema.fetch("required") - data.keys).sort,
          unexpected: (data.keys - properties.keys).sort,
          ill_typed: ill_typed_fields(data, properties)
        }.reject { |_reason, entries| entries.empty? }

        mismatches[event_type] = difference if difference.any?
      end
    end

    # A property-by-property type check, not a JSON Schema engine: a dependency
    # that can validate a document is a dependency this service does not have,
    # and the two payload schemas in core are flat objects of typed scalars. A
    # constraint this does not understand is named in the failure rather than
    # skipped, so a schema that starts using one fails loudly.
    def ill_typed_fields(data, properties)
      data.filter_map do |field, value|
        constraint = properties[field]
        next if constraint.nil?
        next if value_is_type?(constraint.fetch("type"), value)

        "#{field} is #{json_type_of(value)}, core says #{constraint.fetch("type").inspect}"
      end
    end

    def value_is_type?(declared, value)
      case declared
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "boolean" then value.equal?(true) || value.equal?(false)
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "null" then value.nil?
      else raise "this test does not understand type #{declared.inspect}"
      end
    end

    def json_type_of(value)
      case value
      when nil then "null"
      when true, false then "boolean"
      when Integer then "integer"
      when String then "string"
      when Hash then "object"
      when Array then "array"
      else value.class.name
      end
    end

    # --- core's schema, read from disk ---

    def core_path
      @core_path ||= ENV["CORE_PATH"].presence || ENV["CORE_SPECS_PATH"].presence || default_core_path
    end

    def default_core_path
      Rails.root.join("..", "core").expand_path
    end

    def schema
      return @schema if defined?(@schema)

      @schema = begin
        JSON.parse(File.read(File.join(core_path, ENVELOPE_SCHEMA)))
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end
    end

    def manifest
      @manifest ||= YAML.safe_load_file(Rails.root.join(MANIFEST), permitted_classes: [], aliases: false).transform_keys(&:to_s)
    end

    def payload_schema_for(event_type)
      @payload_schemas ||= {}
      @payload_schemas.fetch(event_type) do
        path = File.join(core_path, "schemas", "events", event_type.tr(".", "/") + ".schema.json")

        @payload_schemas[event_type] = begin
          JSON.parse(File.read(path))
        rescue Errno::ENOENT, Errno::ENOTDIR
          nil
        end
      end
    end

    # core's catalog rows, as a set of published event types, keyed by publisher.
    def core_catalog
      return @core_catalog if defined?(@core_catalog)

      text = begin
        File.read(File.join(core_path, "docs", "event-naming.md"))
      rescue Errno::ENOENT, Errno::ENOTDIR
        return @core_catalog = nil
      end

      section = text[/^## Catalog.*?(?=^## )/m]
      billing = section[/^### billing.*?(?=^### |\z)/m]

      @core_catalog = billing.to_s.scan(/^\|\s*`([a-z][a-z0-9_.]+)`\s*\|/).flatten
    end

    # --- the checks, one per constraint core states ---

    # Two patterns are the same grammar if they accept the same strings, so that
    # is what is compared.
    #
    # The obvious alternative — comparing `Regexp#source` against core's pattern
    # string — is what this test used to do, and it is wrong twice over. Ruby's
    # regexp optimiser rewrites `{1,2}` and friends in a way that is not stable
    # across processes, so the same constant can report two different sources on
    # two different runs: a comparison on the text passes once and fails
    # forever after, with nothing changed in between. And even a stable
    # comparison would only prove the two texts are alike, not that they accept
    # the same language. A corpus does prove that.
    GRAMMAR_CORPUS = [
      # What this service emits. Kept as the full list rather than one example:
      # a corpus is only evidence about the strings in it.
      "billing.customer.created",
      "billing.payment.failed",
      "billing.payment.succeeded",
      "billing.plan.created",
      "billing.plan.updated",
      "billing.subscription.canceled",
      "billing.subscription.started",
      "billing.subscription.updated",
      # The other legal shape: two segments.
      "customer.created",
      # A uuid, which is what a subject is in practice.
      "11111111-1111-4111-8111-111111111111",
      "usr_01J9Z8QK5M4N7P2R3T6V8W9X0A",
      # What a webhook's subject is, before this service has its own ids for
      # subscriptions: the processor's.
      "sub_1PZQaBcDeFgHiJkLmNoPqR1",
      # Neighbouring cases, where a grammar difference would show up.
      "identity.api_key.created",
      "billing",
      "customer",
      "",
      "Billing.customer.created",
      "billing.Customer.created",
      "1billing.customer.created",
      "billing..created",
      "billing.customer.",
      ".billing.customer",
      "billing.customer.created.",
      "billing.customer.created.extra",
      "billing-customer.created",
      "billing_customer.created",
      "billing.customer.created ",
      " billing.customer.created",
      "user@example.com",
      "cus_1",
      "-cus_1",
      "_cus_1",
      "cus 1",
      "cus/1",
      "cus:1",
      "cus@1"
    ].freeze

    def assert_same_grammar(core_pattern, ours, corpus = GRAMMAR_CORPUS)
      theirs = Regexp.new(core_pattern)

      disagreements = corpus.reject { |candidate| theirs.match?(candidate) == ours.match?(candidate) }

      assert_empty disagreements, "core and this service disagree about: #{disagreements.inspect}"
    end

    # A property-by-property check, not a JSON Schema engine: a dependency that
    # can validate a document is a dependency this service does not have, and
    # the two payload schemas in core are flat objects of typed scalars. The
    # constraints actually used are asserted, so a schema that starts using
    # something this does not understand fails loudly instead of passing.
    def assert_valid_envelope(envelope)
      properties = schema.fetch("properties")

      # core's `required` is the floor, not the whole set: `subject` is a
      # DECISION NEEDED in core's event-naming.md (D2) and its schema file
      # currently leaves it out of `required` while still constraining it. So
      # the two checks are "everything required is there" and "nothing outside
      # the declared properties is there" — which is what
      # `additionalProperties: false` actually says.
      assert_empty schema.fetch("required") - envelope.keys, "envelope is missing a required attribute"
      assert_empty envelope.keys - properties.keys, "additionalProperties is false in core"

      assert_equal properties.dig("specversion", "const"), envelope.fetch("specversion")
      assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, envelope.fetch("id"))
      assert_within(resolve(properties.fetch("type")), envelope.fetch("type"))
      assert_within(resolve(properties.fetch("source")), envelope.fetch("source"))
      assert_within(properties.fetch("subject"), envelope.fetch("subject"))
      assert_kind_of Hash, envelope.fetch("data")
      assert_time_is_rfc3339(envelope.fetch("time"))
    end

    # core states `type` and `source` as a `$ref` into `$defs`, so the
    # constraints — minLength, maxLength, pattern — are not on the property
    # itself. Following the ref is what makes this a check against core's
    # grammar rather than against a paraphrase of it.
    def resolve(constraint)
      return constraint unless constraint.key?("$ref")

      constraint.fetch("$ref").delete_prefix("#/").split("/").reduce(schema) { |node, key| node.fetch(key) }
    end

    def assert_within(constraint, value)
      assert_kind_of String, value
      assert_operator value.length, :>=, constraint.fetch("minLength")
      assert_operator value.length, :<=, constraint.fetch("maxLength")
      assert_match(/#{constraint.fetch("pattern")}/, value, "#{value.inspect} must match core's pattern")
    end

    def assert_time_is_rfc3339(value)
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, value)
    end
end
