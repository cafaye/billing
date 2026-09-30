# The shape of an identifier, in one place.
#
# This service has three places that need to recognise a uuid — the customer
# owner's cross-service reference, the event subject, and the `:id` of a request
# before it is turned into a query — and they have to agree, or one of them
# starts answering 422 where another answers 500.
module Identifiers
  # Case-insensitive: Postgres compares uuid case-insensitively, so an
  # uppercased uuid from a client is the same uuid and refusing it would be a
  # validation that contradicts the column.
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
end
