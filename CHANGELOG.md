# Changelog

All notable changes to billing are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Billing domain v0 (packet billing-02): customers and plans. Schema, models, the
`/v1` API, and the transactional outbox. No Stripe call.

### Added

- **`customers`** — id uuid, `owner_type` + `owner_id` (a reference to identity's
  `User` or `Account`, stored as a uuid with **no foreign key and no Active
  Record association**, because the class it would associate to lives in another
  service), `processor`, `processor_customer_id`, `email`, `metadata` jsonb,
  timestamps. `UNIQUE [owner_type, owner_id, processor]`, so one owner has one
  customer per processor and a processor migration does not collide on the way
  there.
- **`plans`** — id uuid, `name`, `slug` (unique, kebab-case), `processor_product_id`,
  `processor_price_id`, `amount_cents` (integer, `CHECK >= 0`), `currency`,
  `interval`, `trial_days`, `active`, timestamps. `amount_cents` is an integer of
  **minor units**, not of cents: the name is left as the packet specified it and
  a JPY plan stores 500 in a column called `amount_cents`, which is a naming
  smell recorded rather than silently renamed.
- **`Plan#price` / `Plan#price=`** — the only way an amount enters the model.
  The reader returns a `Money`; the writer accepts nothing else and raises
  `Money::InvalidAmountError` for a bare integer. The two columns are
  `amount_cents` and `currency`, and no code path writes one without the other.
- **`outbox_events`** — core's column list, in core's DDL shape: `id` (the
  envelope's `id`, generated before the insert so a republish dedupes),
  `event_type`, `source`, `subject`, `time`, `data` jsonb, `created_at`,
  `published_at`, `attempts`, with `timestamptz` for the instants and the
  partial index on `(created_at) WHERE published_at IS NULL` that core's
  publisher query needs. Inserted by `after_create`/`after_update`, so the event
  and the change it describes commit or roll back together; a test asserts this
  by rolling back inside a transaction and checking that both rows are gone.
- **Three events, three-segment and service-prefixed as core v0.2 requires**:
  `billing.customer.created`, `billing.plan.created`, `billing.plan.updated`.
  `billing.plan.updated` fires only when a field actually changed.
- **The `/v1` API** — `POST/GET /v1/customers`, `GET/PATCH /v1/customers/:id`,
  `POST/GET /v1/plans`, `GET /v1/plans/:slug`, `PATCH /v1/plans/:id`. Request
  specs written first and shown failing, covering round-trips, the error
  envelope, `409` on a uniqueness collision, `422` on a bad field, cursor paging
  and idempotent replay.
- **`application/problem+json` for every non-2xx**, RFC 9457 with core's
  extensions, built in one place (`app/lib/problem.rb`) so no controller can
  invent a shape. Includes the paths Rails raises into — an unknown `/v1` path
  and an unhandled failure are problem+json too, via
  `config.exceptions_app`, instead of the HTML page Rails would otherwise
  return.
- **`X-Trace-Id` on every response** and in the body of every error, core's rule.
  It is set from the `after_action` *and* from the error renderer, because
  `rescue_from` runs outside the callback chain: without the second call every
  rescued response — every 404, 409 and 422 — would ship without the id support
  starts from.
- **Cursor pagination** on both collections (`data` + `page`, default 25, capped
  at 100, keyset on `(created_at, id)`, 24-hour expiry returning `400
  cursor_expired` rather than silently restarting at page one).
- **`Idempotency-Key` on both POSTs**, backed by an `idempotency_keys` table
  scoped to (endpoint, principal, key) with a request digest, so a replay with
  the same body returns the original response and `Idempotency-Replayed: true`,
  and a replay with a different body is a `409 idempotency_key_reused`. Only
  successful responses are remembered: a frozen 422 would lock a client out for
  24 hours for fixing nothing.
- **`openapi/v1.yaml`** — the HTTP contract, and `cafaye.yml` now declares it
  plus the three published event types. This closes the `> DECISION NEEDED` that
  billing-01 recorded about the absent `exposes`.
- **`test/contract/`** — checks the emitted envelopes against core's real
  `event-envelope.schema.json` (reading core, not paraphrasing it), checks that
  the event-type and subject patterns this service validates with accept
  exactly the strings core's accept, and checks that the manifest and the code
  agree about which events exist and that the OpenAPI document is where the
  manifest says it is.

### Changed

- `core: ^0.1.0` → `^0.2.0` in `cafaye.yml`. Spec v0.2 made three-segment event
  types mandatory, which is a breaking manifest change, and core's own
  guidance is to move the pin in the same commit as the rename.
- `config.consider_all_requests_local` is `false` in the test environment, not
  the generated `true`. With it on, the debug middleware intercepts every error
  response and returns its own HTML page, so no spec could see the thing this
  service promises. This does not make a bug quiet: `show_exceptions =
  :rescuable` still raises anything unexpected, so an unanticipated exception
  fails the suite rather than becoming a 500 the specs have to assert.
- `README.md` and `AGENTS.md` rewritten. Both described a repository with no
  billing logic in it.

### Notes

- **Money at the boundary.** A price arrives as `{"amount_minor": <integer>,
  "currency": "XXX"}` and nothing else. A float and a decimal string are both
  `422`: the float has already lost the fact that it was nineteen dollars
  exactly, and the string would mean this API has two representations for an
  amount. Refused in `MoneyParams`, which is a plain module with no Rails
  dependency, so the rule is unit-shaped rather than controller-shaped.
- **A 422 names `price`, never `amount_cents`.** The client never sends the
  columns, it sends the field they are stored in, so a model error about a column
  is re-reported against the field the caller used — and never twice for one
  problem.
- **Rails `enum` was rejected for `processor` and `interval`.** An enum raises
  `ArgumentError` on an unknown value, which at an HTTP boundary is a `500` for
  something the client got wrong. They are string columns with an inclusion
  validation plus a `CHECK` constraint, so the database still refuses any value
  the model would not have written, and the client gets a `422` naming the field.
- **The outbox column is `event_type`, not `type`.** On any Active Record model
  a column named `type` is single-table inheritance, and a row whose value is
  `billing.customer.created` sends Rails looking for a class with that name. It
  is also what core's DDL says.
- **Migrations do not read model constants.** The `CHECK` constraints inline
  `'stripe'` and `'month', 'year', 'one_time'` rather than reading
  `Customer::PROCESSORS` and `Plan::INTERVALS`, because a migration has to keep
  meaning what it meant the day it ran, even after the model moves on.
- Clocks are injected with `travel_to`, never read. Every timestamp assertion in
  the suite derives from one constant in `test/support/test_support.rb`.

### Not in this release

- **No publisher loop.** The outbox table and the transactional insert are here;
  the process that moves rows to NATS is not. `published_at` is always null,
  `attempts` always zero, and nothing consumes these events yet. This is the one
  gap that is an operational risk rather than a missing convenience, and it is
  the first thing the next packet should close.
- **No authorization.** No endpoint reads a token, because core's JWKS
  verification is not in this repository yet. The `/v1` surface is open and
  `GET /v1/customers` returns every customer, because with no token there is no
  `account_id` to scope a query by. Noted in README under "Known gaps".
- No subscriptions, no Stripe API calls, no webhooks, no invoices, no metered
  usage, no prepaid credit, no `pay_*` tables. Those are later packets and each
  needs its own brief — with the user reviewing the diff, since this is the
  service that holds the money.
- `billing.plan.updated` has no catalog row in core, and none of the three
  events has a payload schema in core. Both are recorded in `cafaye.yml` and
  enforced against this repository by `test/contract/`.
- The cursor is unsigned, the unique-index race path is handled but not
  covered by a spec, and idempotency keys are never pruned. All three are listed
  in README under "Known gaps".

## [0.1.0] - 2026-09-30

The v0 scaffold (packet billing-01). Structure before features: the shape every
later billing packet builds on, with no billing logic in it.

### Added

- Rails 8.1.4 API-only application on Ruby 4.0.1, PostgreSQL adapter, Kamal and
  Thruster for deploys. `Gemfile` dependency floor is Rails' defaults plus `pg`.
- `HealthController` with two probes that answer different questions. `GET
  /healthz` is liveness and touches no dependency, so a slow database cannot
  trigger a restart storm; `GET /readyz` runs `SELECT 1` on a leased connection
  and answers `503 {"status":"error","checks":{"database":"error"}}` when the
  database cannot answer, logging the cause and returning it to nobody.
  Integration-tested on all three paths, including the database-down path, which
  is exercised by faking the leased connection.
- `Money` (`app/models/money.rb`), the seed of the platform rule that money is
  integer minor units and never a Float. A frozen value object of an integer
  amount plus an ISO 4217 currency, with the real exponents for zero-decimal
  (JPY, KRW, VND) and three-decimal (KWD, BHD, OMR) currencies. It refuses rather
  than guesses: a Float amount, a sub-minor-unit amount that would have to be
  rounded, a fractional currency, arithmetic across two currencies, a negative
  result from a subtraction, a non-integer quantity, and any value outside the
  PostgreSQL bigint range. 97 table-driven cases, 100% line and branch coverage
  on the file.
- `db/migrate/20260930000001_init.rb` — a deliberate no-op. The schema lands with
  the Phase 3 packets; `db/schema.rb` is committed so a clean checkout can run
  the suite.
- `bin/prime` as the gate (`bundle install`, `db:prepare`, `rubocop`,
  `rails test`), `mise.toml` pinning Ruby 4.0.1 with the tasks, and
  `docker-compose.yml` running postgres:17 with a healthcheck. The Ruby version
  is written in exactly three places — `mise.toml`, `.ruby-version`, and the
  `Dockerfile` build arg — and they must move in one commit.
- `cafaye.yml`, validated against `core`'s frozen manifest schema. It declares
  identity, language, the `^0.1.0` core constraint, and the SSH remote. It has
  no `exposes`, which is a recorded gap rather than a judgement: that needs an
  OpenAPI 3.1 document, and specs are manager-owned. Marked in the file with a
  `> DECISION NEEDED` callout pointing at `core`'s
  `examples/valid/ruby-api.cafaye.yml`.
- `AGENTS.md` and this changelog, so the conventions that keep money correct are
  written down before the first price is modelled rather than after.

### Notes

- minitest 6 removed `Object#stub` (it moved to the `minitest-mock` gem). Rather
  than add a gem to reach it, `test/test_helper.rb` exposes
  `with_lease_connection`, which wraps the stub registry ActiveSupport already
  ships.
- CI runs Brakeman, `bundler-audit`, RuboCop and the suite. Nothing was
  disabled to make it green. Its PostgreSQL service is pinned to `postgres:17` to
  match `docker-compose.yml`.
- CI is the standalone Rails-generated workflow, not a call to
  `cafaye/kit/workflows/ci.reusable.yml@master`. That workflow is the house
  direction, but it resolves the `kit` repository on GitHub, and `kit` is not
  pushed yet — calling it today would leave every push red. Migrating to it is
  a one-file change once `kit` has a release, and is deliberately not done here.

### Not in this release

No Stripe integration, no customers, plans, subscriptions, metered usage, or
`pay_*` tables. Those are Phase 3 packets and each needs its own brief — with the
user reviewing the diff, since this is the service that holds the money.
