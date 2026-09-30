require "test_helper"

class V1CustomersTest < ActionDispatch::IntegrationTest
  OWNER_ID = "11111111-1111-4111-8111-111111111111"
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
    assert_equal({ "type" => "User", "id" => OWNER_ID }, json_body.fetch("owner"))
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

  test "POST /v1/customers is a 422 for a field the client got wrong" do
    post "/v1/customers", params: { owner_type: "User", owner_id: OWNER_ID, processor: "stripe", email: "nope" }, as: :json

    assert_response :unprocessable_entity
    assert_problem "validation_failed"
    assert_equal [ "email" ], problem_codes
    assert_equal "invalid_format", json_body.fetch("errors").sole.fetch("code")
  end

  test "POST /v1/customers reports every bad field, not just the first" do
    post "/v1/customers", params: { owner_type: "Widget", owner_id: "nope", processor: "braintree" }, as: :json

    assert_response :unprocessable_entity
    assert_equal %w[owner_id owner_type processor], problem_codes.sort
  end

  test "POST /v1/customers with no body is a 422, not a 500" do
    post "/v1/customers", params: {}, as: :json

    assert_response :unprocessable_entity
    assert_problem "validation_failed"
  end

  # --- GET /v1/customers ------------------------------------------------------

  test "GET /v1/customers returns a cursor page, newest first" do
    first = create_customer
    second = create_customer(owner_id: OTHER_OWNER_ID)

    get "/v1/customers"

    assert_response :ok
    assert_equal [ second.id, first.id ], json_body.fetch("data").pluck("id")
    assert_equal({ "next_cursor" => nil, "has_more" => false }, json_body.fetch("page"))
  end

  test "GET /v1/customers returns an empty array rather than nothing" do
    get "/v1/customers"

    assert_response :ok
    assert_equal [], json_body.fetch("data")
  end

  test "GET /v1/customers walks a page at a time without repeating or dropping a row" do
    ids = 3.times.map { |index| create_customer(owner_id: "00000000-0000-4000-8000-00000000000#{index}").id }

    get "/v1/customers", params: { limit: 2 }
    first_page = json_body.fetch("data").pluck("id")
    assert_equal 2, first_page.size
    assert json_body.dig("page", "has_more")

    get "/v1/customers", params: { limit: 2, cursor: json_body.dig("page", "next_cursor") }
    second_page = json_body.fetch("data").pluck("id")

    assert_equal [ ids.first ], second_page
    assert_equal false, json_body.dig("page", "has_more")
    assert_nil json_body.dig("page", "next_cursor")
    assert_equal ids.size, (first_page + second_page).uniq.size
  end

  test "GET /v1/customers defaults to 25 rows" do
    bulk_customers(26)

    get "/v1/customers"

    assert_equal 25, json_body.fetch("data").size
    assert json_body.dig("page", "has_more")
  end

  test "GET /v1/customers caps the page at 100 rows" do
    bulk_customers(101)

    get "/v1/customers", params: { limit: 1000 }

    assert_response :ok
    assert_equal 100, json_body.fetch("data").size
    assert json_body.dig("page", "has_more")
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

  test "GET /v1/customers is a 400 for a cursor older than a day, not a silent restart" do
    # Two customers, so a limit of one actually produces a next_cursor to expire.
    create_customer
    create_customer(owner_id: OTHER_OWNER_ID)
    get "/v1/customers", params: { limit: 1 }
    cursor = json_body.dig("page", "next_cursor")
    assert cursor, "the first page should have a cursor to expire"
    travel 25.hours

    get "/v1/customers", params: { cursor: cursor }

    assert_response :bad_request
    assert_problem "cursor_expired"
  end

  test "GET /v1/customers is oldest-first on request" do
    first = create_customer
    second = create_customer(owner_id: OTHER_OWNER_ID)

    get "/v1/customers", params: { order: "asc" }

    assert_equal [ first.id, second.id ], json_body.fetch("data").pluck("id")
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
      { owner_type: "User", owner_id: OWNER_ID, processor: "stripe", email: "kaka@example.com" }
    end

    def idempotency_headers
      { "Idempotency-Key" => IDEMPOTENCY_KEY }
    end

    # Each row gets its own instant, one second after the last. Without that,
    # every row in a test shares a `created_at` and the order falls to the uuid
    # tiebreaker — which is random, so "newest first" would be an assertion
    # about uuid generation rather than about ordering.
    def create_customer(overrides = {})
      travel 1.second

      Customer.create!({ owner_type: "User", owner_id: OWNER_ID, processor: "stripe", email: "kaka@example.com" }.merge(overrides))
    end

    # For the page-size tests, where only the row count matters and inserting
    # them one at a time through the model would make the suite pay for 100
    # outbox events. `insert_all` skips validations and callbacks, which is
    # fine here: these rows are never validated or announced in this test.
    def bulk_customers(count)
      now = frozen_now
      Customer.insert_all(
        count.times.map do |index|
          {
            id: SecureRandom.uuid,
            owner_type: "User",
            owner_id: format("00000000-0000-4000-8000-%012d", index),
            processor: "stripe",
            metadata: {},
            created_at: now + index,
            updated_at: now + index
          }
        end
      )
    end

    def post_customer
      post "/v1/customers", params: customer_params, as: :json
      assert_response :created
      json_body
    end

    def last_event
      OutboxEvent.order(:created_at, :id).last
    end
end
