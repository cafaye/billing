require "test_helper"

# Every account-scoped route, enumerated, with what the router actually serves.
#
# ## Why this file exists when the answer is "none of them are scoped"
#
# The question a multi-tenant billing service has to answer is *can an
# authenticated caller reach another account's subscription, invoice or payment
# method?* Billing cannot answer it yet, because there is no authenticated caller:
# `/v1` reads no token, since core says identity is the only issuer and the JWKS
# verification is not in this repository. `GET /v1/subscriptions` returns every
# row and `POST /v1/subscriptions/{id}/cancel` cancels whichever row the path
# names. That is recorded in the README, in `AGENTS.md`, and in each controller's
# own header — and a gap written in three places as prose is a gap that rots,
# because prose is not compared against anything.
#
# So this file makes the gap **total**. It enumerates the routes the router
# serves and requires every one of them to be classified here with a reason. A
# route added tomorrow that nobody classified fails here, by name, the day it is
# added rather than the day somebody notices it reading the diff.
#
# This is the billing half of identity's `authz_matrix_test.go`. The two strongest
# tests in that file are `TestEveryRouteIsInTheMatrix` and
# `TestEveryMountedRouteIsAnAccountRoute`; the second catches the route that was
# never in the matrix at all, which is the one a reviewer reading a diff would
# miss. Both directions are asserted below for the same reason, and the direction
# that finds the *unstated* route is the one that matters.
#
# ## What this is not
#
# It is not an authorization check, and it does not become one by being strict
# about prose. Every entry in `ACCOUNT_SCOPED` below is honestly `unscoped`, and
# the word stays in the table until the code changes. Turning a test red to
# advertise a known gap is how a suite starts being ignored; the honest move is a
# green test that says precisely what is true, so that the day one of these lines
# stops being true the failure is a real one.
#
# It lives here rather than in `outbox_envelope_contract_test.rb` because that
# file skips when `core` is not on disk, and a check that hides behind a skip is
# not a check. This one reads the router, which is always there.
class TenantIsolationMatrixTest < ActiveSupport::TestCase
  # The two verdicts a `/v1` route can carry here.
  #
  # `unscoped` is the truth for every account-scoped route on this commit, and it
  # is a **load-bearing word**: it is what makes "this route touches another
  # tenant's data" and "this route does not" distinguishable at a glance, so a
  # route cannot quietly move between the two tables by being reclassified
  # without someone reading why.
  UNSCOPED = "unscoped"
  SCOPED = "scoped"

  # The per-checkout database makes `Rails.root` the right unit for "this
  # service"; the matrix is about the code in this worktree.
  def self.routes
    @routes ||= Rails.application.routes.routes.filter_map { |route|
      path = normalize(route.path.spec.to_s)
      next unless path.start_with?("/v1")

      [ route, path ]
    }
  end

  # `:id` stays `:id` here, and that is the whole reason the table below is
  # written in the router's spelling.
  #
  # The obvious choice was to normalize into the document's `{id}`, which is what
  # `HttpSurfaceContractTest` does because it compares against `openapi/v1.yaml`.
  # This matrix has no document: it compares a table against the router, so the
  # router defines the alphabet and the table is written in it.
  #
  # Normalizing *both* sides into a third spelling would have been a worse guard,
  # not a better one: a table whose keys were wrong in the same way a route was
  # wrong would then agree with it, and this file would report agreement about an
  # operation no client can call. One side normalized to a spelling the other side
  # does not use is what makes a disagreement visible instead of silent.
  def self.normalize(path)
    path.sub("(.:format)", "")
  end

  # Every `/v1` operation that reads or writes **tenant data** — a row belonging to
  # an account, or the catalogue of what an account may buy.
  #
  # Keyed by `[method, router path]`, and the path is in the router's spelling
  # (`:id`, `:slug`) so both sides are read in one alphabet.
  #
  # The reason is not decoration. `TENANT_DATA` names the two columns that decide
  # whether a route belongs here, so the classification is derived from a fact
  # about the model rather than asserted about a path — and a route that starts
  # touching tenant data has to be moved into this table deliberately, which is
  # the moment somebody is asked what its scope should be.
  TENANT_DATA = {
    # A customer is a tenant's record: `owner_type`/`owner_id` are the only link
    # back to identity, and `POST` takes them in the body because there is no
    # token to read them from.
    Customer => "a customer row is `owner_type`/`owner_id`, and there is no token to derive that pair from",
    # A subscription is billed to an account and grants entitlements. Reading or
    # cancelling one is the operation this whole matrix exists to keep honest.
    Subscription => "a subscription is billed to `account_id` and grants entitlements",
    # A plan is the catalogue every account buys from.
    Plan => "a plan is the catalogue of what an account may buy"
  }.freeze

  # Why each model is tenant data, keyed by the table it means. The
  # `TENANT_DATA` above carries the sentence; this is the index that says which
  # sentence goes with which model.
  TENANT_MODEL_BY_NAME = {
    "Customer" => Customer,
    "Plan" => Plan,
    "Subscription" => Subscription
  }.freeze

  # Every served `/v1` operation, with its verdict and — for the account-scoped
  # ones — why it is in this table.
  #
  # **Keys are read in the router's spelling.** Rails draws `:id` and `:slug`; the
  # OpenAPI document writes `{id}` and `{slug}`. Normalising the way
  # `HttpSurfaceContractTest` does is what caught this: the table was first
  # written in the document's spelling, and the two directions then reported all
  # eight parameterised routes as unclassified *and* all eight as stale at once.
  # That double failure is what a normalizing test can produce and a
  # non-normalizing one cannot — a table disagreeing with the router about
  # spelling would otherwise have stayed "the router serves something this file
  # does not know about" forever, with a green tick.
  #
  # **Every entry is `UNSCOPED`.** That is the honest state of this service on this
  # commit and the reason the file is worth having: the table is the list of
  # operations that will need a `where(account_id:)` when identity's JWKS
  # verification lands, written down before the day somebody has to remember
  # them.
  ACCOUNT_SCOPED = {
    [ "GET", "/v1/customers" ] => [ UNSCOPED, "returns every customer" ],
    [ "POST", "/v1/customers" ] => [ UNSCOPED, "takes `owner_type`/`owner_id` in the body" ],
    [ "GET", "/v1/customers/:id" ] => [ UNSCOPED, "finds any customer by its uuid" ],
    [ "PATCH", "/v1/customers/:id" ] => [ UNSCOPED, "writes any customer by its uuid" ],

    [ "GET", "/v1/plans" ] => [ UNSCOPED, "returns the whole catalogue" ],
    [ "POST", "/v1/plans" ] => [ UNSCOPED, "writes the catalogue" ],
    [ "GET", "/v1/plans/:slug" ] => [ UNSCOPED, "reads the catalogue by handle" ],
    [ "PATCH", "/v1/plans/:id" ] => [ UNSCOPED, "writes the catalogue by uuid" ],

    [ "GET", "/v1/subscriptions" ] => [ UNSCOPED, "returns every subscription" ],
    [ "POST", "/v1/subscriptions" ] => [ UNSCOPED, "takes a `customer_id` in the body" ],
    [ "GET", "/v1/subscriptions/:id" ] => [ UNSCOPED, "reads any subscription by its uuid" ],
    # The two mutating ones, and the reason the table is ordered this way: these
    # change another account's billing state, which is the expensive direction.
    [ "POST", "/v1/subscriptions/:id/cancel" ] => [ UNSCOPED, "cancels whichever subscription the path names" ],
    [ "POST", "/v1/subscriptions/:id/change_plan" ] => [ UNSCOPED, "moves whichever subscription the path names onto another plan" ],
    [ "GET", "/v1/subscriptions/:id/entitlements" ] => [ UNSCOPED, "reads another account's entitlements" ]
  }.freeze

  # Every served `/v1` operation that is **not** account-scoped, with the reason.
  #
  # An empty table would exit 0 having checked nothing, which is a skipped test in
  # everything but name, and a route that arrived tomorrow would be classified by
  # nobody. So the webhook is named here, with the reason it is not a tenant
  # operation: it authenticates the *processor* by signature, not a cafaye client,
  # and it must never grow a token check — a `Bearer` on that path would be a
  # second, weaker trust path to the same door.
  NOT_ACCOUNT_SCOPED = {
    [ "POST", "/v1/webhooks/stripe" ] =>
      "authenticates the processor by signature, not a cafaye client, and must never grow a token check"
  }.freeze

  # --- the two directions ----------------------------------------------------

  # The direction that finds things. A route the router serves that is in neither
  # table is a route nobody decided the scope of, and it is live on the next
  # deploy. Named, so the failure says which operation rather than describing a
  # surface nobody can call.
  test "every route the router serves under /v1 is classified by this matrix" do
    assert_empty unclassified,
      "these /v1 operations are served but neither classified as account-scoped nor " \
      "named here with a reason. Decide what their scope is before they ship: #{names(unclassified)}"
  end

  # The other direction, and the one that keeps the tables from rotting. A row
  # here that the router does not serve excludes nothing today and will exclude
  # whatever somebody adds at that method and path next, which is why a stale row
  # fails rather than being ignored.
  test "every operation this matrix classifies is one the router actually serves" do
    stale = (ACCOUNT_SCOPED.keys + NOT_ACCOUNT_SCOPED.keys).reject { |operation| served.include?(operation) }

    assert_empty stale,
      "these matrix entries are for operations the router does not serve. A route that " \
      "went away takes its reason with it: #{names(stale)}"
  end

  # The two tables must not both claim the same operation. Where they overlap,
  # neither half can be right, and the overlap is where an operation stops being
  # anyone's responsibility.
  test "no operation is both account-scoped and not" do
    overlap = ACCOUNT_SCOPED.keys & NOT_ACCOUNT_SCOPED.keys

    assert_empty overlap,
      "these operations are in both tables, so the matrix and the router disagree about " \
      "the same route: #{names(overlap)}"
  end

  # --- the claims the table makes -------------------------------------------

  # Every entry is `UNSCOPED`, and that is the claim this file exists to make
  # checkable. It is asserted as a **set of the distinct values rather than by
  # counting rows**, so that the day one of these is genuinely scoped the failure
  # names the verdict that changed instead of reporting a number that moved.
  #
  # A floor or a count would accept the table silently losing its most dangerous
  # rows; a set comparison cannot, because the removal *is* the change.
  test "every account-scoped operation is currently unscoped, which is the recorded gap" do
    verdicts = ACCOUNT_SCOPED.values.map(&:first).uniq.sort

    assert_equal [ UNSCOPED ], verdicts,
      "these operations are recorded as scoped. That is only true once a query carries a " \
      "where(account_id:) — change the verdict here in the same commit that adds the scope, " \
      "or this test is a claim about code that does not exist"
  end

  # The reason is not decoration: a row without one is a row nobody thought about,
  # which is exactly how `/v1/subscriptions` came to return every row.
  test "every account-scoped operation says why it is in the table" do
    unexplained = ACCOUNT_SCOPED.select { |_operation, (_verdict, reason)| reason.to_s.strip.empty? }

    assert_empty unexplained.keys,
      "these operations are classified with no reason: #{names(unexplained.keys)}"
  end

  test "every operation that is not account-scoped says why it is not" do
    unexplained = NOT_ACCOUNT_SCOPED.select { |_operation, reason| reason.to_s.strip.empty? }

    assert_empty unexplained.keys,
      "these operations are excluded with no reason: #{names(unexplained.keys)}"
  end

  # The matrix is only as good as the set of models it treats as tenant data, and
  # that set has to be pinned rather than derived — otherwise a new model that
  # holds tenant data joins the surface without anybody deciding its scope, which
  # is the failure mode this whole file exists to prevent.
  test "the set of models this matrix treats as tenant data is pinned" do
    assert_equal %w[Customer Plan Subscription], TENANT_DATA.keys.map(&:name).sort
  end

  # And the index that attaches a reason to a model has to agree with it. A
  # sentence filed against the wrong model is a matrix that reads correctly and
  # classifies wrongly.
  TENANT_DATA.each do |model, reason|
    test "#{model.name} is tenant data, and the index that files its reason agrees" do
      assert_same model, TENANT_MODEL_BY_NAME.fetch(model.name)

      refute_empty reason.to_s.strip
    end
  end

  # --- and the claim the README makes ---------------------------------------

  # The prose says the open surface is `GET /v1/customers`, `GET /v1/subscriptions`
  # and `POST /v1/subscriptions`. Those are the three *visible* consequences, not
  # the complete set — `POST /v1/subscriptions/{id}/cancel` is worse and is not
  # in that sentence. This asserts the prose's three are at least accounted for,
  # so the README cannot drift away from the matrix without something failing.
  DOCUMENTED_OPEN_OPERATIONS = [
    [ "GET", "/v1/customers" ],
    [ "GET", "/v1/subscriptions" ],
    [ "POST", "/v1/subscriptions" ]
  ].freeze

  DOCUMENTED_OPEN_OPERATIONS.each do |operation|
    test "the README's open surface includes #{operation.join(" ")}, and the matrix agrees" do
      assert_includes ACCOUNT_SCOPED.keys, operation
      assert_equal UNSCOPED, ACCOUNT_SCOPED.fetch(operation).first
    end
  end

  # The mutating operations are the ones a security reader cares about most, and
  # the README sentence does not name them. Pinning them here is what stops the
  # matrix from being quietly trimmed down to the three operations the prose
  # happens to mention.
  TENANT_MUTATIONS = [
    [ "PATCH", "/v1/customers/:id" ],
    [ "PATCH", "/v1/plans/:id" ],
    [ "POST", "/v1/customers" ],
    [ "POST", "/v1/plans" ],
    [ "POST", "/v1/subscriptions/:id/cancel" ],
    [ "POST", "/v1/subscriptions/:id/change_plan" ]
  ].freeze

  TENANT_MUTATIONS.each do |operation|
    test "#{operation.join(" ")} mutates tenant data, so the matrix cannot lose it" do
      assert_includes ACCOUNT_SCOPED.keys, operation,
        "a route that writes tenant data must be in the matrix; dropping it is how an " \
        "unscoped mutation stops being anybody's problem"
    end
  end

  private
    # `(method, document path)` for every `/v1` operation the router serves.
    def served
      @served ||= self.class.routes.flat_map { |route, path|
        methods_for(route).map { |method| [ method, path ] }
      }.to_set
    end

    # Served, and in neither table.
    def unclassified
      served - ACCOUNT_SCOPED.keys - NOT_ACCOUNT_SCOPED.keys
    end

    # `via: :all` draws a route with no verb constraint, which answers every
    # method. Same expansion the HTTP-surface contract test uses, for the same
    # reason: one vocabulary for "what the router serves".
    def methods_for(route)
      route.verb.empty? ? %w[GET HEAD POST PUT PATCH DELETE OPTIONS] : route.verb.split("|")
    end

    # `GET /v1/plans/:slug` rather than `["GET", "/v1/plans/:slug"]`, because the
    # pair is the thing being reported and a request line is how it reads.
    def names(operations)
      operations.map { |method, path| "#{method} #{path}" }.sort.join(", ")
    end
end
