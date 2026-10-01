module TestSupport
  # A real identity, for the suite.
  #
  # ## Why this is not a fake verifier
  #
  # The obvious way to test a token check is to stub the verifier and hand the
  # controller a principal. That proves the controller reads the thing it was
  # given, and proves nothing about whether the token would have verified — which
  # is the only part of this that can be wrong in a way an attacker reaches.
  #
  # So the suite runs the **real** `Identity::TokenVerifier` against a **real**
  # RSA key: 2048 bits, generated once per process, with the matching JWKS served
  # from an in-process fetch. Every request in the suite carries a genuinely signed
  # token, and `test/authentication/token_verifier_test.rb` proves the refusals by
  # presenting tokens this suite minted with the wrong key, the wrong issuer, the
  # wrong audience and an expiry in the past.
  #
  ## The shape, and the three things that matter about it
  #
  #   * **`IDENTITY_ISSUER` and `IDENTITY_AUDIENCE` are set for the whole suite**, so
  #     an ordinary `/v1` request verifies. They are credentials for nothing: no
  #     network is reached and the key is discarded with the process.
  #   * **The JWKS comes from `jwks_source`, not from the network.** A test that
  #     asserted billing verifies a token by fetching from a real identity would be
  #     a test that fails when identity is down and passes when it is up, which is
  #     the wrong axis. The fetch is stubbed; the **verification is not**.
  #   * **The key is generated once, lazily**, because a 2048-bit RSA generation is
  #     about a hundred milliseconds and the suite runs in parallel across eight
  #     workers.
  module TestIdentity
    AUDIENCE = "billing".freeze
    KID = "test-key-1".freeze

    # A second key, for the token that must not verify. It signs nothing this
    # service trusts, so a token carrying it is refused as an unknown key.
    FOREIGN_KID = "test-key-not-published".freeze

    class << self
      def issuer = "https://identity.test"

      # The signing key, generated once per process.
      def private_key
        @private_key ||= OpenSSL::PKey::RSA.generate(2048)
      end

      def foreign_key
        @foreign_key ||= OpenSSL::PKey::RSA.generate(2048)
      end

      # The JWKS `identity` would publish. Built from `private_key`, so the key in
      # the set and the key that signs are the same one, and the `Foreign` variant
      # is what makes "signed by a key this service does not publish" expressible.
      # `JWT::JWK::Set#export` returns a Hash with **symbol** keys; a JWKS document
      # off the wire has string keys, because it went through JSON. The round trip
      # is not tidiness — it is what makes the stub the same shape as the real
      # response, so a verifier that read `document[:keys]` would fail in production
      # and pass here. Reading the symbol-keyed Hash here would have hidden exactly
      # that.
      def jwks
        @jwks ||= exported([ JWT::JWK.new(private_key.public_key, kid: KID) ])
      end

      def jwks_with_foreign_key
        @jwks_with_foreign_key ||= exported([
          JWT::JWK.new(private_key.public_key, kid: KID),
          JWT::JWK.new(foreign_key.public_key, kid: FOREIGN_KID)
        ])
      end

      def exported(keys)
        JSON.parse(JWT::JWK::Set.new(keys).export.to_json)
      end

      # A configured verifier whose fetch is answered from this module. `jwks` may
      # be a callable so a test can make the fetch raise, which is how the
      # "identity is unreachable" branch is exercised without a network.
      def verifier(jwks_source: nil, **overrides)
        source = jwks_source || ->(_url) { jwks }
        Identity::TokenVerifier.new(
          issuer: issuer,
          audience: AUDIENCE,
          jwks_source: source,
          **overrides
        )
      end

      # A bearer token this suite's verifier accepts.
      #
      # Defaults are the shape identity issues (see `wt-identity-21`'s
      # `internal/oidc/storage.go`): `sub`, `iss`, `aud`, `exp`, `iat`, `jti`, an
      # `account_id`, and the space-separated `scope` string RFC 9068 registers.
      def token(account_id: Account, subject: "user-#{Account}", scopes: %w[openid accounts],
                expires_at: nil, issued_at: nil, key: nil, kid: KID,
                issuer: self.issuer, audience: AUDIENCE, claims: {})
        payload = {
          "iss" => issuer,
          "aud" => audience,
          "sub" => subject,
          "account_id" => account_id,
          "scope" => Array(scopes).join(" "),
          "jti" => "jti-#{SecureRandom.hex(8)}",
          "iat" => (issued_at || 1.minute.ago).to_i,
          "exp" => (expires_at || 15.minutes.from_now).to_i
        }.merge(claims).compact

        # **`.compact`, and the reason is worth one line.** A spec that wants to
        # prove a token is refused for a missing claim has to produce a token the
        # claim is *absent* from, and `merge` with a nil would leave the key present
        # with a null value — which is a different document, and for `iat` a null is
        # rejected by the `jwt` gem on the way out rather than by the verifier on the
        # way in. So a nil in `claims` means "remove this claim".
        JWT.encode(payload, key || private_key, "RS256", { kid: kid })
      end

      # An expired token: signed correctly, `exp` in the past, so the only thing
      # wrong with it is the clock. A structurally broken token would prove the
      # parser works, not the expiry.
      def expired_token(account_id: Account, **rest)
        token(account_id: account_id, expires_at: 1.minute.ago, issued_at: 1.hour.ago, **rest)
      end

      # A token signed by a key this service's JWKS does not publish.
      def foreign_token(account_id: Account, **rest)
        token(account_id: account_id, key: foreign_key, kid: FOREIGN_KID, **rest)
      end

      # Points `Identity::TokenVerifier.current` at a verifier for the duration of
      # the block and puts the previous one back, so one test's configuration cannot
      # leak into the next in a shared process.
      def with_verifier(verifier)
        previous = Identity::TokenVerifier.current
        Identity::TokenVerifier.current = verifier
        yield
      ensure
        Identity::TokenVerifier.current = previous
      end

      # The configuration every request in the suite runs under: identity present,
      # JWKS answering from this module. `test_helper.rb` installs it once.
      def install_default!
        ENV["BILLING_IDENTITY_ISSUER"] = issuer
        ENV["BILLING_IDENTITY_AUDIENCE"] = AUDIENCE
        Identity::TokenVerifier.current = verifier
      end

      # The environment this suite runs under, as a hash, so a spec that needs the
      # lock can delete the configuration and restore it afterwards.
      def configuration
        { "BILLING_IDENTITY_ISSUER" => issuer, "BILLING_IDENTITY_AUDIENCE" => AUDIENCE }
      end

      # **This service configured no identity at all**, for the block.
      #
      # Two things have to change and forgetting either produces a test that passes
      # without proving the lock: the variables are unset, *and* the memoized
      # `TokenVerifier.current` is rebuilt from them. Deleting the variables alone
      # leaves the verifier from `install_default!` in place — still holding the
      # issuer and audience it was built with — so every request verifies and the
      # test asserts nothing.
      def with_no_configuration
        previous_verifier = Identity::TokenVerifier.current
        previous_env = configuration
        begin
          previous_env.each_key { |name| ENV.delete(name) }
          Identity::TokenVerifier.current = Identity::TokenVerifier.new
          yield
        ensure
          previous_env.each { |name, value| ENV[name] = value }
          Identity::TokenVerifier.current = previous_verifier
        end
      end
    end

    # The two account uuids the auth specs use, distinct from
    # `TwoAccounts::ACCOUNT_A/B` so a failure message says which pair it is about.
    # Same obviously-fake shape: `3333…` and `4444…`, values nothing mints.
    Account = "33333333-3333-4333-8333-333333333333".freeze
    OtherAccount = "44444444-4444-4444-8444-444444444444".freeze
  end
end

module ActiveSupport
  class TestCase
    # The Authorization header for a caller acting as `account_id`. Every request
    # spec on `/v1` goes through here rather than building the header itself, so
    # "what does an authenticated request look like" has one answer.
    def auth_headers(account_id: TestSupport::TestIdentity::Account, **rest)
      { "Authorization" => "Bearer #{TestSupport::TestIdentity.token(account_id: account_id, **rest)}" }
    end
  end
end

# **`/v1` needs a token, so every integration spec arrives with one.**
#
# Reopened on `ActionDispatch::IntegrationTest` **by its full name**, because
# `class IntegrationTest` inside `module ActiveSupport` would *define* a new class
# rather than reopen one — and the test would then pass having installed a default
# header on nothing.
#
# Set as a **default header** rather than passed per request, and that is the
# point: there are ~150 request specs and passing the header at each would mean 150
# places to forget, and a spec that forgot would assert the *lock* rather than the
# behaviour — passing while the surface it meant to test was closed. The specs that
# mean to test the lock (`test/authentication/`) remove it explicitly.
ActionDispatch::IntegrationTest.class_eval do
  # `headers` on an integration test is the **response's** headers — `Runner`
  # delegates it to `response`, and `response` is nil before the first request — so
  # there is no request-headers accumulator to merge a default into. These wrappers
  # are the equivalent, and `super` is what keeps them honest: the verb still goes
  # to Rails' own `get`/`post`/…, which is the only thing that builds the request.
  %i[get post patch put head delete].each do |verb|
    define_method(verb) do |path, **args|
      super(path, **args, headers: request_headers.merge(args[:headers] || {}))
    end
  end

  # Every test starts as the default authenticated caller. Not tidiness: `acts_as`
  # and `with_raw_token` are per-test state, and a worker process running many tests
  # must not carry the previous test's identity into the next one.
  setup do
    @acting_account = nil
    @token_overrides = nil
    @raw_token = nil
    @raw_header = nil
  end

  # Acts as another account from here on, for the rest of the test.
  def acts_as(account_id, **rest)
    @acting_account = account_id
    @token_overrides = rest
  end

  # The header gone, for a spec about what an unauthenticated caller gets.
  def without_token!
    @acting_account = false
  end

  # A caller holding `token` verbatim, which is what the refusal specs need: a
  # token this suite minted but with one thing wrong.
  def with_raw_token(token)
    @raw_token = token
  end

  # The whole `Authorization` header, verbatim, for the shapes a token cannot
  # express — a non-bearer scheme, a lower-cased one, two of them at once.
  def with_authorization_header(value)
    @raw_header = value
  end

  private
    # What every request in this test carries, unless a spec took it away.
    #
    # `false` rather than `nil` for "no token", because `nil` is also what a spec
    # that never asked for one would produce, and the difference between "anonymously"
    # and "explicitly anonymous" is not one a test should be able to get wrong by
    # accident.
    def request_headers
      return {} if @acting_account == false
      return { "Authorization" => @raw_header } if @raw_header
      return { "Authorization" => "Bearer #{@raw_token}" } if @raw_token

      { "Authorization" => "Bearer #{TestSupport::TestIdentity.token(
        account_id: @acting_account || TestSupport::TestIdentity::Account,
        **(@token_overrides || {})
      )}" }
    end
end
