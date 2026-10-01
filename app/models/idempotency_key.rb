# The stored record of a mutating POST that already happened.
#
# core: a retriable POST must accept `Idempotency-Key`; a replay with the same
# key *and the same body* returns the original response with
# `Idempotency-Replayed: true`; a replay with the same key and a different body
# is a 409 `idempotency_key_reused`. Requests without the key are processed
# normally — that is the client's call, and this service does not second-guess it.
#
# Only a successful response is remembered. A 422 is the client being told what
# to fix, and freezing that answer for 24 hours would mean a client that fixes
# its body and retries with the same key still cannot get through. A retried
# failure re-evaluates, which is the only useful behaviour here.
class IdempotencyKey < ApplicationRecord
  RETENTION = 24.hours

  # **The principal is the token's `sub`, and it is passed in rather than
  # resolved here.** core defines the scope as `(endpoint, principal, key)`, and a
  # key scoped to nobody is a key any caller can replay another's answer under: two
  # tenants choosing the same uuid would have shared one namespace, and a replay
  # under a key the *other* tenant used would have returned that tenant's stored
  # 201 to whoever guessed the uuid. The `principal` column is already in the unique
  # index, so this is a value and not a migration.
  #
  # The `sub` claim and not `account_id`: two users in one account are two callers,
  # and a replay under one user's key must not answer for the other's.
  validates :endpoint, :principal, :key, :request_digest, :response_body, presence: true

  # The stored response for this exact request, or nil if the key is new.
  # Raises when the key was used for a *different* body, which is a client bug
  # rather than a retry and must not be answered with someone else's response.
  def self.replay_for(endpoint:, principal:, key:, digest:)
    record = find_by(endpoint: endpoint, principal: principal, key: key)
    return nil if record.nil?

    raise IdempotencyKeyReused, key if record.request_digest != digest

    record
  end

  def self.remember(endpoint:, principal:, key:, digest:, status:, body:)
    create!(
      endpoint: endpoint,
      principal: principal,
      key: key,
      request_digest: digest,
      status: status,
      response_body: body
    )
  end

  # Older than core's retention window. The index on `created_at` exists for
  # exactly this scan; scheduling it is a later packet (see README).
  scope :expired, -> { where("created_at < ?", Time.current - RETENTION) }
end
