# The one condition core's idempotency rules call a 409: the same
# `Idempotency-Key` on the same endpoint for the same caller, with a different
# body. The key is a promise about one request; changing the request under it
# is either a client bug or a key collision, and both mean the stored response
# is not an answer to this request.
class IdempotencyKeyReused < StandardError
  attr_reader :key

  def initialize(key)
    @key = key
    super("idempotency key #{key} was already used for a different request body")
  end
end
