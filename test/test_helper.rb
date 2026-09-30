ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Spec helpers. Plain modules, no framework gem.
Dir[Rails.root.join("test/support/**/*.rb")].sort.each { |file| require file }

# Fake collaborators for a single test.
#
# minitest 6 dropped `Object#stub` (it moved to the separate minitest-mock gem,
# which this service does not depend on), so we use the stub registry that
# ActiveSupport already keeps for time helpers. Stubs are also removed
# automatically in `after_teardown`; the block form below restores them sooner,
# so a failing assertion cannot leak a stub into the next test.
module StubbedCollaborators
  # Makes `ActiveRecord::Base.lease_connection` return `connection` for the
  # duration of the block. Used to simulate a database that is down.
  def with_lease_connection(connection)
    simple_stubs.stub_object(ActiveRecord::Base, :lease_connection) { connection }
    yield
  ensure
    simple_stubs.unstub_all!
  end
end

module ActiveSupport
  class TestCase
    include StubbedCollaborators
    include TestSupport::FrozenClock
    include TestSupport::ApiHelpers

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
