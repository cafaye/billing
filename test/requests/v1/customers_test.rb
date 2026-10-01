require "test_helper"

class V1CustomersTest < ActionDispatch::IntegrationTest
  # The account these fixtures belong to, and therefore the one the token names. It is
  # **the authenticated account**, and that is the point: every query on `/v1` is
  # scoped by the token's `account_id`, and `Customer.for_account` matches
  # `owner_type: "Account"` with `owner_id` equal to it. A fixture owned by any other
  # uuid is invisible to the request, so a spec using one would pass while asserting
  # the *scoping* rather than the behaviour it means to.
  #
  # billing-21 is what made this necessary, and it is the same value
  # `test/support/stripe_subscription_fixtures.rb` uses for its own customers — so the
  # two request specs cannot disagree about who the caller is.
  OWNER_ID = TestSupport::TestIdentity::Account

  # A second account, for the cases that need a row belonging to somebody else.
  OTHER_OWNER_ID = "22222222-2222-4222-8222-222222222222"

  IDEMPOTENCY_KEY = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

  setup do
    travel_to(frozen_now)
  end

  # --- POST /v1/customers -----------------------------------------------------

  test "POST /v1/customers creates a customer and returns it" do
    post "/v1/customers",
      params: { owner_type: "User", owner_id: OWNER_ID, processor: "stripe", email: "kaka@example.com" },
      as: :json

    assert_response :created
    customer = Customer.sole
    # **`owner_type` is `"Account"` and the body said `"User"`.** That is billing-21:
    # the owner comes from the token, so a customer created through `/v1` is always
    # billed to the caller's account. A row owned by a `User` has no account to scope
    # by, so creating one here would write a row no caller could read back.
    assert_equal({ "type" => "Account", "id" => OWNER_ID }, json_body.fetch("owner"))
    assert_equal "stripe", json_body.fetch("processor")
    assert_nil json_body.fetch("processor_customer_id")
    assert_equal customer.id, json_body.fetch("id")
    assert_equal frozen_now.iso8601, json_body.fetch("created_at")
    assert_equal "/v1/customers/#{customer.id}", response.headers["Location"]
  end

  test "POST /v1/customers emits billing.customer.created in the same transaction" do
    post "/v1/customers", params: { owner_type: "User", owner_id: OWNER_ID, processor: "stripe" }, as: :json

    assert_response :created
    event = OutboxEvent.sole
    assert_equal "billing.customer.created", event.event_type
    assert_equal json_body.fetch("id"), event.subject
  end

  test "POST /v1/customers is a 409 when the owner already has one on that processor" do
    create_customer

    assert_no_difference [ "Customer.count", "OutboxEvent.count" ] do
      post "/v1/customers", params: { owner_type: "User", owner_id: OWNER_ID, processor: "stripe" }, as: :json
    end

    assert_response :conflict
    assert_problem "conflict"
  end

  # The collision `POST` cannot reach any more, and that is worth its own test.
  #
  # `customers` is unique on `(owner_type, owner_id, processor)`, and since billing-21
  # the owner is the token's account — so a caller who already holds a customer on
  # `stripe` gets that 409 before `processor_customer_id` is ever considered. That is
  # strictly safer, and it means the "another `cus_`" case is only reachable for an
  # account that holds **none**, which is the case below.
  test "POST /v1/customers is a 409 on another account's processor customer id" do
    other_accounts = Customer.create!(
      owner_type: "Account", owner_id: OTHER_OWNER_ID, processor: "stripe",
      processor_customer_id: "cus_FAKEsomebodyelseBBBBBBBBBB"
    )

    post "/v1/customers",
      params: { processor: "stripe", processor_customer_id: other_accounts.processor_customer_id },
      as: :json

    assert_response :conflict
    assert_problem "conflict"
    assert_match(/processor_customer_id/, response.body,
      "the 409 must name the field. The caller holds no customer at all, so the only thing this " \
      "request collides with is that id, and a 409 that did not say so would send a client " \
      "looking for a collision that is not there.")
  end

  # A 409 is not an error in the model, so nothing is half-written: the row the
  # caller owns is exactly as it was. A conflict that left the field changed would
  # be a different bug, and a *worse* one, because the caller would believe it had
  # moved.
  #
  # **The victim is created by the model, not through `POST`.** Since billing-21 the
  # owner is the token's account, so a `POST` cannot create a second customer for the
  # same `(owner, processor)` — the collision above is the point. The victim's row is
  # still reachable through the `PATCH` because a `PATCH` does not change the owner,
  # and that is the case this test is about: the one field on this resource a client
  # can move onto somebody else's.
  test "a refused processor customer id leaves the caller's own row untouched" do
    victim = Customer.create!(
      owner_type: "Account", owner_id: OTHER_OWNER_ID, processor: "stripe",
      processor_customer_id: "cus_FAKEvictimBBBBBBBBBBBBB"
    )
    caller = create_customer(processor_customer_id: "cus_FAKEcallerAAAAAAAAA")

    patch "/v1/customers/#{caller.id}",
      params: { processor_customer_id: victim.processor_customer_id },
      as: :json

    assert_response :conflict
    assert_match(/processor_customer_id/, response.body)
    assert_equal "cus_FAKEcallerAAAAAAAAA", caller.reload.processor_customer_id,
      "the refused field was written anyway"
    assert_equal "cus_FAKEvictimBBBBBBBBBBBBB", victim.reload.processor_customer_id
  end

  # The other direction, and the one that would break every client if it were
  # wrong: a `cus_` nobody holds yet is accepted, and setting the same value the
  # row already holds is not a collision with itself.
  test "PATCH /v1/customers/:id accepts a processor customer id nobody holds" do
    customer = create_customer(processor_customer_id: "cus_FAKEmineAAAAAAAAAA")

    patch "/v1/customers/#{customer.id}",
      params: { processor_customer_id: "cus_FAKEnewoneBBBBBBBBBBBB" },
      as: :json

    assert_response :ok
    assert_equal "cus_FAKEnewoneBBBBBBBBBBBB", customer.reload.processor_customer_id
  end

  test "PATCH /v1/customers/:id accepts setting the processor customer id to the value it already holds" do
    customer = create_customer(processor_customer_id: "cus_FAKEsameAAAAAAAAAAA")

    patch "/v1/customers/#{customer.id}",
      params: { processor_customer_id: "cus_FAKEsameAAAAAAAAAAA" },
      as: :json

    assert_response :ok
    assert_equal "cus_FAKEsameAAAAAAAAAAA", customer.reload.processor_customer_id
  end

  test "POST /v1/customers is a 422 for a field the client got wrong" do
    post "/v1/customers", params: { owner_type: "User", owner_id: OWNER_ID, processor: "stripe", email: "nope" }, as: :json

    assert_response :unprocessable_entity
    assert_problem "validation_failed"
    assert_equal [ "email" ], problem_codes
    assert_equal "invalid_format", json_body.fetch("errors").sole.fetch("code")
  end

  test "POST /v1/customers reports every bad field, not just the first" do
    post "/v1/customers", params: { owner_type: "Widget", owner_id: "nope", processor: "braintree", email: "nope" }, as: :json

    assert_response :unprocessable_entity
    # **`owner_id` and `owner_type` are not in this list any more.** Since billing-21
    # the controller writes `owner_type: "Account"` and `owner_id: current_account_id`
    # **after** `permit`, so whatever the body sent for them is not the value that
    # reaches the model — and a body field the service ignores is not a problem with
    # the request, so there is nothing to report. What is left is the two fields the
    # client can actually get wrong.
    assert_equal %w[email processor], problem_codes.sort
  end

  # The other half of that, and the assertion that matters: a client that sends a
  # *malformed* owner gets no 422 and no row owned by what it sent. Silently ignoring
  # the field would be the alternative, and it would leave a client believing it had
  # created a customer for somebody else.
  test "POST /v1/customers ignores the body's owner entirely, valid or not" do
    post "/v1/customers",
      params: { owner_type: "Widget", owner_id: "not-a-uuid", processor: "stripe" },
      as: :json

    assert_response :created
    assert_equal "Account", json_body.dig("owner", "type")
    assert_equal OWNER_ID, json_body.dig("owner", "id")
    assert_equal OWNER_ID, Customer.sole.owner_id
  end

  test "POST /v1/customers with no body is a 422, not a 500" do
    post "/v1/customers", params: {}, as: :json

    assert_response :unprocessable_entity
    assert_problem "validation_failed"
  end

  # --- GET /v1/customers ------------------------------------------------------
  #
  # ## The paging tests moved to `plans_test.rb`, and that is a real consequence
  #
  # Until billing-21 a customer listing could hold one row per `(owner, processor)`
  # across **every** account, so these specs built 26 or 101 of them and paged
  # through. Since the owner is the token's account and `Customer::PROCESSORS` is
  # `%w[stripe]`, **an account's customer listing holds at most one row.** There is
  # no honest way to arrange a 101-row customer page any more, and a fixture that
  # reached past the unique index to fake one would be asserting pagination on a
  # collection that cannot exist.
  #
  # So the cursor behaviour is proved on `/v1/plans`, which is platform catalogue and
  # genuinely does grow, and what is left here is what is true about *this* listing:
  # it is this account's, and it is at most one row.

  test "GET /v1/customers returns this account's customer" do
    mine = create_customer

    get "/v1/customers"

    assert_response :ok
    assert_equal [ mine.id ], json_body.fetch("data").pluck("id")
    assert_equal({ "next_cursor" => nil, "has_more" => false }, json_body.fetch("page"))
  end

  test "GET /v1/customers returns an empty array rather than nothing" do
    get "/v1/customers"

    assert_response :ok
    assert_equal [], json_body.fetch("data")
  end

  test "GET /v1/customers is a 422 for a limit that is not a count" do
    get "/v1/customers", params: { limit: "all" }

    assert_response :unprocessable_entity
    assert_problem "validation_failed"
  end

  test "GET /v1/customers is a 400 for a cursor it cannot read" do
    get "/v1/customers", params: { cursor: "not-base64url" }

    assert_response :bad_request
    assert_problem "cursor_invalid"
  end

  # An account holds one customer per processor, so its listing cannot overflow a page.
  #
  # **Proved at the index rather than at the listing**, because that is where the
  # property lives: the second write is refused by the database, so there is no second
  # row for the listing to return. Asserting "the listing has at most one row" by
  # building two rows needs a fixture that reaches past the unique index, and a test
  # built on such a fixture proves something the schema already guarantees.
  test "GET /v1/customers cannot overflow a page, because one customer per account per processor is unique" do
    create_customer

    second = Customer.new(owner_type: "Account", owner_id: OWNER_ID, processor: "stripe")
    assert_raises(ActiveRecord::RecordNotUnique) do
      second.save!(validate: false)
    end

    get "/v1/customers"

    assert_response :ok
    assert_equal 1, json_body.fetch("data").size
    refute json_body.dig("page", "has_more"),
      "the listing reports more pages, so it believes it holds rows this account cannot have"
  end

  # --- GET /v1/customers/:id --------------------------------------------------

  test "GET /v1/customers/:id round-trips what POST created" do
    created = post_customer

    get "/v1/customers/#{created.fetch("id")}"

    assert_response :ok
    assert_equal created, json_body
  end

  test "GET /v1/customers/:id is a 404 for an id that does not exist" do
    get "/v1/customers/99999999-9999-4999-8999-999999999999"

    assert_response :not_found
    assert_problem "not_found"
  end

  test "GET /v1/customers/:id is a 404 for an id that is not an id" do
    get "/v1/customers/someone-elses-customer"

    assert_response :not_found
    assert_problem "not_found"
  end

  # --- PATCH /v1/customers/:id ------------------------------------------------

  test "PATCH /v1/customers/:id updates the customer" do
    customer = create_customer

    patch "/v1/customers/#{customer.id}", params: { email: "new@example.com" }, as: :json

    assert_response :ok
    assert_equal "new@example.com", json_body.fetch("email")
    assert_equal "new@example.com", customer.reload.email
  end

  test "PATCH /v1/customers/:id leaves the fields it was not given alone" do
    create_customer(email: "kaka@example.com", metadata: { "tenant" => "kaka" })

    patch "/v1/customers/#{Customer.sole.id}", params: { email: "new@example.com" }, as: :json

    assert_equal({ "tenant" => "kaka" }, json_body.fetch("metadata"))
  end

  test "PATCH /v1/customers/:id is a 422 for a bad field" do
    customer = create_customer

    patch "/v1/customers/#{customer.id}", params: { email: "nope" }, as: :json

    assert_response :unprocessable_entity
    assert_problem "validation_failed"
    assert_equal "kaka@example.com", customer.reload.email
  end

  test "PATCH /v1/customers/:id is a 404 for an id that does not exist" do
    patch "/v1/customers/99999999-9999-4999-8999-999999999999", params: { email: "new@example.com" }, as: :json

    assert_response :not_found
    assert_problem "not_found"
  end

  test "PATCH /v1/customers/:id emits no event, because the packet defines none for it" do
    customer = create_customer
    last_event

    assert_no_difference("OutboxEvent.count") do
      patch "/v1/customers/#{customer.id}", params: { email: "new@example.com" }, as: :json
    end
  end

  # --- idempotency ------------------------------------------------------------

  test "POST /v1/customers replays the original response for the same key and body" do
    post "/v1/customers", params: customer_params, headers: idempotency_headers, as: :json
    assert_response :created
    original = json_body

    assert_no_difference [ "Customer.count", "OutboxEvent.count" ] do
      post "/v1/customers", params: customer_params, headers: idempotency_headers, as: :json
    end

    assert_response :created
    assert_equal original, json_body
    assert_equal "true", response.headers["Idempotency-Replayed"]
  end

  test "POST /v1/customers is a 409 when a key is reused for a different body" do
    post "/v1/customers", params: customer_params, headers: idempotency_headers, as: :json
    assert_response :created

    post "/v1/customers", params: customer_params.merge(email: "other@example.com"), headers: idempotency_headers, as: :json

    assert_response :conflict
    assert_problem "idempotency_key_reused"
  end

  test "POST /v1/customers without a key is processed normally" do
    post "/v1/customers", params: customer_params, as: :json

    assert_response :created
    assert_nil response.headers["Idempotency-Replayed"]
  end

  private
    def customer_params
      # **`owner_type`/`owner_id` are here and are ignored.** `POST /v1/customers`
      # writes the token's account onto the row, so sending them exercises the ignore
      # path — the body carries an owner and the response must not be it.
      { owner_type: "Account", owner_id: OWNER_ID, processor: "stripe", email: "kaka@example.com" }
    end

    def idempotency_headers
      { "Idempotency-Key" => IDEMPOTENCY_KEY }
    end

    # Each row gets its own instant, one second after the last. Without that,
    # every row in a test shares a `created_at` and the order falls to the uuid
    # tiebreaker — which is random, so "newest first" would be an assertion
    # about uuid generation rather than about ordering.
    #
    # **`owner_type: "Account"`, and that is a change from billing-20's `"User"`.**
    # `Customer.for_account` matches `owner_type: "Account"` with the token's
    # `account_id`, so a `User`-owned fixture is in no account's scope and this
    # spec's requests would return an empty listing — passing while asserting the
    # scoping. See `test/tenant/cross_account_web_test.rb` for the `User`-owned case,
    # which is the one place it is still the subject.
    def create_customer(overrides = {})
      travel 1.second

      Customer.create!({ owner_type: "Account", owner_id: OWNER_ID, processor: "stripe", email: "kaka@example.com" }.merge(overrides))
    end

    # `bulk_customers` and `inserted_customer` are **both gone**, and that is a real
    # consequence rather than tidiness.
    #
    # They built 26 and 101 customers for the page-size tests, which was possible while
    # a listing returned every account's rows. Since billing-21 the owner is the token's
    # account and `customers` is unique on `(owner_type, owner_id, processor)`, so an
    # account's listing holds at most one row: there is no honest 101-row customer page
    # to walk, and building one needs a fixture that reaches past the unique index — which
    # would be a test asserting something the schema already guarantees. The cursor
    # behaviour moved to `test/requests/v1/plans_test.rb`, where the collection is
    # platform catalogue and genuinely grows.
    #
    # Deleting the helpers rather than leaving them unused is deliberate: an unused
    # fixture that reaches past a unique index is a trap for whoever next needs two rows
    # and does not know why they are hard to make.
    def post_customer
      post "/v1/customers", params: customer_params, as: :json
      assert_response :created
      json_body
    end

    def last_event
      OutboxEvent.order(:created_at, :id).last
    end
end
