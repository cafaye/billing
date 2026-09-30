# AGENTS.md — billing

This file is the contract an agent (or a new hire) reads before touching this
repository. If a rule is not written here, it is not a rule.

## What this service is

- **Name:** `billing` — the cafaye namespace name, the repository name, and the
  `source` on every event this service eventually publishes.
- **Language / toolchain:** Ruby 4.0.1 on Rails 8.1, API-only — pinned in
  `mise.toml`, `.ruby-version`, and the `ARG RUBY_VERSION` in the `Dockerfile`.
  Those three must agree in one commit.
- **Owns:** plans, subscriptions, prepaid credit, usage metering, and webhooks
  in. One responsibility: the platform's money.
- **Does not own:** who the caller is (`identity`), how mail reaches them
  (`courier`), what a `pantry` catalogue looks like. billing is a service behind
  the gateway, not a public door.
- **Upstream specs:** `core`'s `cafaye.yml` manifest, OpenAPI, and event
  schemas. The spec is the source of truth; the code follows it, never the
  reverse. `cafaye.yml` in this repository is a draft and carries a
  `> DECISION NEEDED` callout — read it before changing the manifest.

## v0 is a scaffold, on purpose

There is no billing logic in this repository yet. What exists is the shape every
later packet builds on — health probes and the money primitive — plus the
conventions that keep money correct. Do not read the absence of plans,
subscriptions or Stripe as something to fix in a side patch; those are Phase 3
packets with their own briefs.

## Layout

```
billing/
├── mise.toml               # toolchain pins + the tasks (mise run prime)
├── bin/prime               # the gate: bundle, db:prepare, rubocop, rails test
├── docker-compose.yml      # local postgres:17, the only service in the stack
├── Dockerfile              # ruby slim, multi-stage, non-root, via Kamal/Thruster
├── cafaye.yml              # the manifest draft (DECISION NEEDED on `exposes`)
├── app/
│   ├── controllers/health_controller.rb   # /healthz, /readyz
│   └── models/money.rb                    # the money primitive
├── test/
│   ├── integration/health_test.rb
│   └── models/money_test.rb
└── .github/workflows/ci.yml # brakeman, bundler-audit, rubocop, rails test
```

## Commands

Run these; do not improvise equivalents.

| Task | Command |
|------|---------|
| Prime the worktree | `bin/prime` (or `mise run prime`) |
| Prime without lint or tests | `bin/prime --fast` |
| Run the test suite | `bin/rails test` |
| Run one file | `bin/rails test test/models/money_test.rb` |
| Run the linter | `bin/rubocop --parallel` |
| Security scan | `bin/bundler-audit check --update` and `bin/brakeman --no-pager` |
| Start the database | `docker compose up -d` |
| Everything CI runs | `bin/prime`, plus the two security scans |

## Money

`app/models/money.rb` is the seed of the platform-wide rule that **money is
integer minor units** and never a Float. Read its class comment before changing
it. The rules that are not negotiable:

- Amounts are integers of minor units. A Float is rejected on the way in, not
  converted — `0.1` cannot represent a dime, so it never carries an amount.
- Nothing rounds. `Money.from_major("10.505", "USD")` raises
  `Money::InvalidAmountError`. A silently rounded price is a bug that surfaces
  in somebody's invoice, which is the worst place to find one.
- Every operation is range-checked against the PostgreSQL bigint bounds, so an
  unstorable value is refused at the edge instead of at the database.
- Mixing currencies is an error, never a conversion. FX is a pricing decision.
- Quantities are integers and go on the right: `price * 3`, never `3 * price`.
- Store and transmit `minor_units` and `currency`. A major-unit decimal is a
  display format; `Money#to_major` exists for interop and must not be persisted.

Money paths are held to **100% line and branch coverage** (PLAN §3), measured
with Ruby's standard library `Coverage` (`Coverage.start(branches: true)`) so the
gate costs no gem. The table-driven cases in `test/models/money_test.rb` are the
gate: every row must be reachable and asserted.

## Testing

- Tests are written **first**, and shown failing before the implementation.
- No sleeps, no raised retries, no loosened assertions. A flaky test is
  attributed before it is fixed: failing test → can this diff reach that
  surface → measure the baseline at a clean HEAD.
- The database-down path is exercised for real, not asserted about: fake the
  leased connection with `with_lease_connection` in `test/test_helper.rb`.
  minitest 6 removed `Object#stub` (it moved to the `minitest-mock` gem, which
  this service does not depend on), so that helper wraps the stub registry
  ActiveSupport already ships. Do not reintroduce the removed API.
- Raising a threshold is allowed. Lowering one, or adding an inline lint
  disable to make a build green, is not.

## Conventions

- **Never** edit `Gemfile.lock` as a side effect. A lockfile change is its own
  commit with its own reason. `bin/prime` only ever runs `bundle install`.
- **Never** copy code from `moon/refs/` into this repository. `jumpstart-pro` is
  a licensed product and the shallow clones are behavioral references only;
  every line here is written from scratch (PLAN §2).
- **Never** add a gem without saying so in the PR body. Rails defaults and `pg`
  are the current floor; a new dependency is a decision, not a convenience.
- Errors are raised at the boundary with the identifier needed to find the
  failing row, not just a message — and a failure message never returns to an
  HTTP caller. `/readyz` logs the database error and answers a generic 503.
- Time is UTC. IDs are opaque strings. The schema lands in Phase 3; the
  `00001` migration is a deliberate no-op and `db/schema.rb` is committed.

## Contracts

- The two probes are infrastructure, not contract surface. They are not in
  `cafaye.yml`'s `exposes` and must not grow query parameters, auth, or a
  versioned payload — an uptime monitor is the only reader.
- Every endpoint and event this service publishes is generated from `core`'s
  specs and validated in CI. Never hand-write a response shape.
- Breaking a contract is a major version plus a migration note in `README.md`
  and `CHANGELOG.md`, reviewed by a human — not a patch.

## Before you open a PR

- [ ] `bin/prime` is green from a clean worktree
- [ ] New behavior has a test that fails without it
- [ ] Money changes keep 100% line and branch coverage on `money.rb`
- [ ] Lint and security scans are green, and nothing was disabled to get there
- [ ] `AGENTS.md` still describes the repository as it now is
- [ ] `CHANGELOG.md` has an entry
