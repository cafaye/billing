require "test_helper"

class HealthTest < ActionDispatch::IntegrationTest
  test "GET /healthz reports ok" do
    get "/healthz"

    assert_response :ok
    assert_equal({ "status" => "ok" }, response.parsed_body)
  end

  test "GET /healthz does not depend on the database" do
    with_lease_connection(raising_connection) do
      get "/healthz"
    end

    assert_response :ok
    assert_equal({ "status" => "ok" }, response.parsed_body)
  end

  test "GET /readyz reports ok when the database answers" do
    get "/readyz"

    assert_response :ok
    assert_equal({ "status" => "ok", "checks" => { "database" => "ok" } }, response.parsed_body)
  end

  test "GET /readyz returns 503 JSON when the database is unavailable" do
    with_lease_connection(raising_connection) do
      get "/readyz"
    end

    assert_response :service_unavailable
    assert_equal({ "status" => "error", "checks" => { "database" => "error" } }, response.parsed_body)
  end

  test "GET /readyz does not leak the database error to the client" do
    with_lease_connection(raising_connection) do
      get "/readyz"
    end

    assert_no_match(/no database/, response.body)
  end

  private
    def raising_connection
      Object.new.tap do |connection|
        connection.define_singleton_method(:exec_query) { |*| raise ActiveRecord::ConnectionNotEstablished, "no database" }
      end
    end
end
