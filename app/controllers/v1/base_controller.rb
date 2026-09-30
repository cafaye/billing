# What /v1 has in common, which is less than it looks like: the version prefix
# is routing's job, and everything else about a response comes from the
# concerns on ApplicationController.
module V1
  class BaseController < ApplicationController
    private
      # Postgres parses a `uuid` column before Rails gets to decide whether a
      # row exists, so `find` with a malformed id is a database error rather
      # than a missing record. An id that cannot be one of ours is a 404, and
      # that has to be decided before the query, not after the exception.
      def uuid_param!(value)
        raise ActiveRecord::RecordNotFound unless Identifiers::UUID.match?(value.to_s)

        value
      end
  end
end
