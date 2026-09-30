require "test_helper"

# Cross-account behaviour on the HTTP surface, and the `403` audit.
#
# ## The honest position on this file
#
# `/v1` has no caller. There is no token, so there is no "account A" to send a
# request as, and a wire-level *account A asks for account B's resource* cannot
# be written here — there is no A. That is the recorded gap, held by
# `contract/tenant_isolation_matrix_test.rb` and by each controller's own header.
#
# So this file does two things instead, and both are things the gap does not
# make impossible:
#
#   1. **It pins the half of "absence, not refusal" that is available today.** A
#      resource that does not exist and an identifier that *cannot* name one are
#      already the same answer, byte for byte, because `V1::BaseController#uuid_param!`
#      decides before the query and `ProblemResponses#render_not_found` renders one
#      fixed sentence. That is the property scoping will extend to another
#      account's row, and it is worth having already true — a 404 that echoed the
#      identifier, or that differed by *why*, would be an enumeration oracle
#      today and a worse one after scoping.
#
#   2. **It pins the gap as a tripwire that fires when the gap closes.** The
#      characterisation tests below assert that another account's row is
#      reachable — which is a green test saying precisely what is true, not a red
#      one advertising a known hole. Each is coupled to `account_scoped_queries`,
#      which counts the account-constrained queries in `app/`. The day scoping
#      lands, that count stops being zero, these tests fail, and their names say
#      what to do about it.
#
# ## Why the gap is not closed by adding a 404
#
# It is tempting to answer "another account's row" with a 404 today. It would be
# a lie: without a caller there is no other account, so the 404 would be a
# refusal of a request that is in fact legitimate, and it would break every client
# while pretending to be a security fix. The brief is explicit that adding 403s is
# out of scope, and the same reasoning covers 404s.
class TenantCrossAccountWebTest < ActionDispatch::IntegrationTest
  # The two kinds of "no": a uuid that belongs to no row, and a string that is not
  # a uuid and therefore cannot belong to any row. Both must be one answer.
  MISSING_UUID = "99999999-9999-4999-8999-999999999999".freeze

  class << self
    # The tests in this file, read at **run** time — the `test` macro defines each
    # method as the class body is evaluated, so a count taken while the body is
    # still executing would see only the tests above it.
    #
    # `public_instance_methods(false)` rather than `instance_methods`, so the
    # helpers `ActionDispatch::IntegrationTest` contributes are not counted.
    def negative_test_methods
      public_instance_methods(false).grep(/\Atest_/).reject { |method| method.to_s.start_with?("test_meta:") }.sort
    end
  end

  # A sentinel that exists only to be recognised. It is set on **account B's**
  # row, because the characterisation tests read B's row: a 200 about B proves the
  # gap by returning a value only B had. `assert_includes body, sentinel` would
  # print the body on failure — which on this surface is the other account's
  # billing data — so those assertions use `include?` directly and put a sentence
  # in the message instead. The sentinel is a made-up address on the reserved
  # `.invalid` TLD, so it is recognisable as a fixture in any log it reaches.
  SENTINEL_EMAIL = "account-b-sentinel@example.invalid".freeze

  # The value the cross-account PATCH writes. **Different from the sentinel on
  # purpose**: writing a row the value it already holds is a no-op, and a no-op
  # cannot distinguish "the write reached the other account" from "the write
  # reached nobody". Two sentinels, so the assertion is about a change.
  REWRITTEN_EMAIL = "account-b-rewritten@example.invalid".freeze

  setup do
    travel_to(frozen_now)
    create_account_customers
    create_account_subscriptions
    customer_b.update!(email: SENTINEL_EMAIL)
  end

  # --- absence, not refusal -------------------------------------------------

  # The property, on all three uuid-addressed resources, in one test each so a
  # failure names which resource started answering differently.
  #
  # `render_not_found` renders exactly one sentence, "No record matches that
  # identifier.", with no branch for *why* the identifier failed. So the two
  # answers are not merely both 404 — they are the same document, and the only
  # fields that differ are the ones that differ on every request: the trace id
  # and the path echoed in `instance`.
  ADDRESSED_BY_UUID = [
    [ "a customer", ->(id) { "/v1/customers/#{id}" } ],
    [ "a plan", ->(id) { "/v1/plans/#{id}" } ],
    [ "a subscription", ->(id) { "/v1/subscriptions/#{id}" } ]
  ].freeze

  ADDRESSED_BY_UUID.each do |label, path_for|
    test "read: #{label} answers a missing uuid and an impossible id identically" do
      get path_for.call(MISSING_UUID)
      missing = problem_without_request_echo

      assert_response :not_found
      assert_problem "not_found"

      get path_for.call("not-a-uuid")
      impossible = problem_without_request_echo

      assert_response :not_found
      assert_problem "not_found"
      assert_equal missing, impossible,
        "a #{label} that does not exist and an id that cannot name one must be the same " \
        "answer. They differ in: #{(missing.keys | impossible.keys).reject { |key| missing[key] == impossible[key] }.inspect}"
    end
  end

  # Plans are addressed by slug on the way in and by uuid on the way out, so the
  # slug path gets its own case: a handle nobody wrote has to be the same answer
  # as a handle that was never a uuid. The two lookups are deliberately different
  # and both are 404 for the other's identifier, which the routes file says and
  # this holds to.
  test "read: a plan answers a slug nobody wrote and a uuid nobody wrote identically" do
    get "/v1/plans/no-such-plan-ever"
    by_slug = problem_without_request_echo
    assert_response :not_found

    get "/v1/plans/#{MISSING_UUID}"
    by_uuid = problem_without_request_echo
    assert_response :not_found

    assert_equal by_slug, by_uuid,
      "a plan addressed two different ways must be absent in the same way. They differ in: " \
      "#{(by_slug.keys | by_uuid.keys).reject { |key| by_slug[key] == by_uuid[key] }.inspect}"
  end

  # A 404 carries the whole of what a 404 may carry, and nothing else.
  #
  # **The interesting field is `instance`**, which is the request path — so a 404
  # *does* repeat the identifier it refused. That is not an oracle, and the
  # distinction is worth making precisely: the identifier is the caller's own
  # input, echoed back to a caller who already has it, which discloses nothing.
  # An oracle would be the 404 saying anything the caller did not send — a price, a
  # plan, a status, an address, or *which of several reasons* it refused.
  #
  # So the property asserted here is that the body is the caller's input and a
  # fixed sentence, and carries nothing about any row. That is what makes a 404
  # safe to reuse for another account's row when scoping lands, and it is the
  # reason a 404 that grew a second `detail` for "exists but not yours" would be
  # the first thing to break.
  ADDRESSED_BY_UUID.each do |label, path_for|
    test "read: the 404 for #{label} carries the caller's own path and one fixed sentence" do
      get path_for.call(MISSING_UUID)

      assert_response :not_found
      assert_equal %w[code detail instance status title trace_id type], json_body.keys.sort,
        "the 404's shape changed. A field this list does not name is a field that could " \
        "carry something about the resource it refused."
      assert_equal "No record matches that identifier.", json_body["detail"],
        "the 404's detail now says something specific. Two sentences is the shape of an " \
        "enumeration oracle: one for 'does not exist' and one for 'exists, not yours'."
      assert_equal path_for.call(MISSING_UUID), json_body["instance"],
        "`instance` is the caller's own request path. It echoes input the caller already " \
        "has, which is safe; it must never carry anything the caller did not send."
      refute response.body.include?(SENTINEL_EMAIL),
        "a 404 carried a customer's address. The absent case must be absent in full."
    end
  end

  # --- the 403 audit --------------------------------------------------------

  # **Zero 403s, and it is structural rather than a survey.**
  #
  # The brief's rule is that a 403 on a resource the caller cannot see is an
  # enumeration oracle: it says "this exists, you may not have it", where a 404
  # says nothing. So the check is not "we did not write a 403 today" but "this
  # service has no way to emit one" — the problem vocabulary is a **frozen table**,
  # `Problem::CATALOG`, and a status outside it cannot be rendered at all.
  #
  # That makes the guarantee a property of a closed set rather than of a review,
  # which is why it is asserted against the whole table and not against a grep.
  test "read: this service cannot emit a 403, so it cannot be an enumeration oracle" do
    statuses = Problem::CATALOG.values.map { |entry| Rack::Utils.status_code(entry.fetch(:status)) }

    refute_includes statuses, 403,
      "a 403 was added to the problem vocabulary. A 403 on a resource the caller cannot " \
      "see distinguishes it from one that does not exist, which is exactly the " \
      "enumeration oracle this service must not have. Use 404, or nil at the query."
    assert_equal statuses.uniq.sort, [ 400, 404, 409, 422, 500, 503 ],
      "the problem vocabulary's statuses changed. This service answers 404 for absence, " \
      "never 403."
  end

  # The same fact from the source side, so a `render_problem` reached with a raw
  # status — bypassing `CATALOG` — would be caught even though `CATALOG` did not
  # change. The two directions are asserted separately because a comparison that
  # stops at the first of them hides the second behind it.
  test "read: no controller renders a 403 by any route" do
    offenders = app_sources.select { |path, source| source.match?(/\b403\b|forbidden|:unauthorized/i) }

    assert_empty offenders.keys,
      "these files name a 403, `forbidden` or an unauthorized status. Absence is " \
      "not refusal: a resource the caller may not see must be indistinguishable " \
      "from one that does not exist. Offenders: #{offenders.keys.inspect}"
  end

  # --- the recorded gap, pinned as a tripwire -------------------------------

  # The characterisation tests. Each asserts what is **true today** — that another
  # account's row is reachable — and each is coupled to `account_scoped_queries`,
  # so the day the gap closes they fail with a message that says what to do.
  #
  # The sentinel, not the payload, is what these assert on. "Account A received
  # account B's data" is provable by noticing that a value only B had turned up in
  # A's response; it is not provable — and must not be demonstrated — by printing
  # the response.
  test "gap: read — a customer is reachable by its uuid alone, with no account to check it against" do
    assert_equal 0, account_scoped_queries,
      "account scoping has landed. This test asserted the gap; it must now be rewritten " \
      "to assert a 404, and so must every other characterisation test in this file."

    get "/v1/customers/#{customer_b.id}"

    assert_response :ok
    assert response.body.include?(SENTINEL_EMAIL),
      "expected account B's sentinel to come back for a request that named only B's uuid. " \
      "If it does not, the gap has closed and this test is now wrong rather than the " \
      "service being right for a reason nobody wrote down."
  end

  test "gap: read — a subscription is reachable by its uuid alone" do
    assert_equal 0, account_scoped_queries, "see the characterisation test above"

    get "/v1/subscriptions/#{subscription_b.id}"

    assert_response :ok
    assert_equal subscription_b.id, json_body["id"]
    assert_equal ACCOUNT_B, json_body["account_id"],
      "the response should still name the other account's subscription. If it does not, " \
      "the gap has closed and this test is wrong."
  end

  # A read is a disclosure; a **write** to another account's row is the expensive
  # direction, and it is the one a reader of the matrix should not have to take on
  # trust from the fact that the read is open. So the write is exercised: account
  # A's PATCH reaches account B's customer and changes it.
  test "gap: update — a customer is writable by its uuid alone, with no account to check it against" do
    assert_equal 0, account_scoped_queries, "see the characterisation test above"
    before = fingerprint([ customer_b ])

    patch "/v1/customers/#{customer_b.id}", params: { email: REWRITTEN_EMAIL }, as: :json

    assert_response :ok
    assert_equal [ customer_b.id ], drifted_ids(before, [ customer_b ]),
      "the PATCH named only account B's uuid, so account B's row was expected to change. " \
      "If it did not, the gap has closed and this test is wrong."
  end

  test "gap: list — a subscription listing is not scoped to an account" do
    assert_equal 0, account_scoped_queries, "see the characterisation test above"

    get "/v1/subscriptions"

    assert_response :ok
    assert_includes json_body.fetch("data").map { |row| row.fetch("id") }, subscription_b.id,
      "account B's subscription was expected in the listing. If it is absent, the gap has " \
      "closed and this test is wrong."
  end

  # --- meta: the counts this file claims -----------------------------------

  test "meta: this file holds 13 negative tests over 0 account-scoped queries" do
    assert_equal 13, self.class.negative_test_methods.size
    assert_equal 0, account_scoped_queries
  end

  # The tripwire above is only as good as the thing it counts, so the count is
  # pinned: `where(account_id:` is the shape scoping will take, and there is
  # exactly one other spelling worth watching — a scope method, which would be a
  # new entry point in the matrix rather than a new query here.
  test "meta: the count that drives the tripwire is a count of account-constrained queries" do
    assert_equal 0, account_scoped_queries
    assert_empty app_sources.select { |_path, source| source.match?(/\.for_account\b/) },
      "a `for_account` scope has appeared. That is the shape account scoping will take, and " \
      "it is a new account-scoped entry point that the matrix must classify."
  end

  # The characterisation tests are held together by one thing: each of them asserts
  # `account_scoped_queries == 0`, and each is prefixed `gap:` so the set is
  # countable. The prefix is a convention and this assertion is what makes it a
  # fact — four tests carry it, and four is the number the report quotes, so a
  # fifth characterisation written without the prefix fails here rather than
  # quietly joining the boundary tests and making the file look better covered than
  # it is.
  test "meta: the four characterisation tests are the ones that assert the gap is open" do
    gap_prefixed = self.class.negative_test_methods.select { |method| method.to_s.start_with?("test_gap:") }

    assert_equal 4, gap_prefixed.size,
      "the number of tests that assert the gap rather than a boundary changed. Every one of " \
      "them must be rewritten when scoping lands, so the count is worth noticing."
    assert_equal 0, account_scoped_queries
  end

  private
    # The 404 body without the two fields that differ on every request: the trace
    # id and the path echoed in `instance`. Everything else must match exactly.
    def problem_without_request_echo
      json_body.except("trace_id", "instance")
    end

    # How many queries in `app/` constrain on an account. Zero today, and the
    # whole characterisation set above is coupled to it.
    #
    # Two shapes, because scoping will plausibly arrive in either: a `where`/
    # `find_by` with `account_id:` in it, or a named scope. The second is counted
    # separately because a scope is a *new* entry point in the matrix, not a
    # modification of an existing query.
    def account_scoped_queries
      app_sources.values.sum { |source| source.scan(/(?:where|find|find_by|find_by!)\(.*?account_id:/).size }
    end

    def app_sources
      @app_sources ||= Dir[Rails.root.join("app/**/*.rb")].to_h { |path|
        [ Pathname(path).relative_path_from(Rails.root).to_s, File.read(path) ]
      }
    end
end
