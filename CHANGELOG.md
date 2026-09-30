# Changelog

All notable changes to billing are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

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
