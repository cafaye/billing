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

  # Events with no payload schema in core, which core's outbox checklist asks for.
  # Core ships two (identity's and billing's subscription.started) and neither is
  # this service's. Same reasoning: recorded, not ignored, and this list is what
  # fails if a new event is published without anyone noticing the schema is owed.
  NO_PAYLOAD_SCHEMA_YET = OutboxEvent::TYPES

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
    # Core ships two payload schemas in total and neither is billing's, so today
    # this checks the accounting and nothing else. It is the thing that notices
    # the day a schema lands, rather than the payload drifting until a consumer
    # breaks.
    validated = []

    envelopes.each do |envelope|
      schema = payload_schema_for(envelope.fetch("type"))
      next if schema.nil?

      assert_matches_payload_schema(schema, envelope.fetch("data"), envelope.fetch("type"))
      validated << envelope.fetch("type")
    end

    unspecified = OutboxEvent::TYPES - validated

    assert_equal NO_PAYLOAD_SCHEMA_YET.sort, unspecified.sort,
      "the set of events with no payload schema in core has changed: drop the entries this service no longer owes one for"
  end

  test "the manifest declares an api, and the document it points at exists" do
    api = manifest.fetch("exposes").fetch("api")

    assert_path_exists Rails.root.join(api)
  end

  private
    # --- the fixtures under test: real emissions, not hand-built envelopes ---

    def envelopes
      customer = Customer.create!(owner_type: "User", owner_id: "11111111-1111-4111-8111-111111111111", processor: "stripe")
      plan = Plan.create!(name: "Pro monthly", slug: "pro-monthly", price: Money.new(1900, "USD"), interval: "month")
      plan.update!(active: false)

      OutboxEvent.order(:created_at, :id).map(&:to_envelope)
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

    # A property-by-property check, not a JSON Schema engine: a dependency that
    # can validate a document is a dependency this service does not have, and
    # the two payload schemas in core are flat objects of typed scalars. The
    # constraints actually used are asserted, so a schema that starts using
    # something this does not understand fails loudly instead of passing.
    def assert_matches_payload_schema(schema, data, event_type)
      properties = schema.fetch("properties")

      assert_equal schema.fetch("required").sort, data.keys.sort, "#{event_type}: payload keys must be exactly core's required set"
      assert_empty data.keys - properties.keys, "#{event_type}: additionalProperties is false in core"

      data.each do |field, value|
        constraint = properties.fetch(field)

        case constraint.fetch("type")
        when "string" then assert_kind_of String, value, "#{event_type}.#{field}"
        when "integer" then assert_kind_of Integer, value, "#{event_type}.#{field}"
        when "boolean" then assert_equal [ true, false ], value.class == TrueClass || value.class == FalseClass ? value : nil, "#{event_type}.#{field}"
        when "object" then assert_kind_of Hash, value, "#{event_type}.#{field}"
        when "array" then assert_kind_of Array, value, "#{event_type}.#{field}"
        when "null" then assert_nil value, "#{event_type}.#{field}"
        else raise "#{event_type}.#{field}: this test does not understand type #{constraint.fetch("type").inspect}"
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
      # What this service emits.
      "billing.customer.created",
      "billing.plan.created",
      "billing.plan.updated",
      # The other legal shape: two segments.
      "customer.created",
      # A uuid, which is what a subject is in practice.
      "11111111-1111-4111-8111-111111111111",
      "usr_01J9Z8QK5M4N7P2R3T6V8W9X0A",
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

    def assert_same_grammar(core_pattern, ours)
      theirs = Regexp.new(core_pattern)

      disagreements = GRAMMAR_CORPUS.reject { |candidate| theirs.match?(candidate) == ours.match?(candidate) }

      assert_empty disagreements, "core and this service disagree about: #{disagreements.inspect}"
    end

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
