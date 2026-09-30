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
- **Upstream specs:** `core`'s `cafaye.yml` manifest schema, event envelope and
  payload schemas, and `docs/openapi-conventions.md` + `docs/event-outbox.md`.
  This repository is pinned to `core: ^0.2.0`. The spec is the source of truth;
  the code follows it, never the reverse. `cafaye.yml` carries `> DECISION
  NEEDED` callouts recording the obligations this worktree could not discharge —
  read them before changing the manifest, and do not delete one to make a
  complaint go away.
- **core is read-only from a service worktree.** When core is missing something
  this service owes it — a catalog row, a payload schema, a reserved error code —
  the obligation is recorded in `cafaye.yml` *and* asserted in `test/contract/`,
  and the action item is named in the worker report. Writing into core from here
  is out of bounds.

## What exists so far

Two packets, in order.

- **billing-01** was a scaffold: health probes and the money primitive. It
  exists so the shape was settled before the first price was modelled.
- **billing-02** is the billing domain v0: `customers` and `plans`, the `/v1`
  API over them, and a transactional outbox that writes
  `billing.customer.created`, `billing.plan.created` and `billing.plan.updated`
  in the same transaction as the change they describe. No Stripe call.
- **billing-03b** is the Stripe webhook: `POST /v1/webhooks/stripe`, signature
  verification over the raw body, and `processor_webhooks` as the
  at-most-once record of what arrived. It emits five more events —
  `billing.subscription.started|updated|canceled` and
  `billing.payment.succeeded|failed` — into **billing-02's** outbox. It still
  makes no Stripe API call; it only receives.

There are no subscriptions, invoices, payments or usage metering yet. Do not
read their absence as something to fix in a side patch; those are later packets
with their own briefs. The webhook is how those packets will learn that
something happened — it is not the state, only the report of it.

## Layout

```
billing/
├── mise.toml               # toolchain pins + the tasks (mise run prime)
├── bin/prime               # the gate: bundle, db:prepare, rubocop, rails test
├── docker-compose.yml      # local postgres:17, the only service in the stack
├── Dockerfile              # ruby slim, multi-stage, non-root, via Kamal/Thruster
├── cafaye.yml              # the manifest; DECISION NEEDED notes are load-bearing
├── openapi/v1.yaml         # the HTTP contract, and what `exposes.api` points at
├── app/
│   ├── controllers/
│   │   ├── health_controller.rb       # /healthz, /readyz
│   │   ├── errors_controller.rb       # what Rails raises into
│   │   ├── concerns/                  # trace id, problem+json, paging, idempotency
│   │   ├── v1/                        # customers, plans
│   │   └── webhooks/                  # signed inbound, from a processor not a client
│   ├── lib/
│   │   ├── problem.rb                 # the one error shape
│   │   ├── money_params.rb            # the only place a request becomes an amount
│   │   └── identifiers.rb             # the uuid shape, in one place
│   ├── models/
│   │   ├── money.rb                   # the money primitive
│   │   ├── customer.rb                # owner_type + owner_id, one per processor
│   │   ├── plan.rb                    # price is a Money or it is not a price
│   │   ├── processor_webhook.rb       # what a processor sent, stored once
│   │   └── outbox_event.rb            # the event, and the envelope it becomes
│   └── services/
│       └── webhooks/                  # verify, store, normalize, emit — in that order
├── test/
│   ├── contract/                      # the checks that read core
│   ├── integration/                   # health, and the webhook's HTTP edge
│   ├── models/                        # minitest, table-driven
│   ├── requests/v1/                   # the API specs
│   └── services/webhooks/             # ingestion and the Stripe mapping
└── .github/workflows/ci.yml           # brakeman, bundler-audit, rubocop, rails test
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
- **The wire carries minor units and an integer, and one representation only.**
  `{"amount_minor": 1900, "currency": "USD"}`. A Float and a decimal string are
  both refused at the edge by `app/lib/money_params.rb`, which is a plain module
  with no Rails dependency. Do not add a second accepted shape to be helpful.
- `Plan#price` returns a `Money` and `Plan#price=` accepts only a `Money`.
  `amount_cents` and `currency` are written by that setter and by nothing else.
  A 422 about an amount names `price` — the field the client sent — and never
  the columns underneath it.

Money paths are held to **100% line and branch coverage** (PLAN §3), measured
with Ruby's standard library `Coverage` (`Coverage.start(branches: true)`) so the
gate costs no gem. The table-driven cases in `test/models/money_test.rb` are the
gate: every row must be reachable and asserted.

## Events

The rules are core's, in `core: docs/event-outbox.md` and
`docs/event-naming.md`. What is not negotiable here:

- An event is written in **the same transaction** as the change it describes,
  from `after_create`/`after_update` — never `after_commit`, and never a
  background job. A separate transaction is a window in which the database says
  the plan exists and the event does not.
- The type is `<service>.<entity>.<action>`, three segments, prefixed with this
  service's own name (core v0.2, D1). `OutboxEvent::TYPES` and `cafaye.yml`'s
  `exposes.events` are the same list, and `test/contract/` fails if they drift.
- A type is not published unless core's catalog has a row for it. An event with
  no catalog row is a manifest that lies to whoever generates an SDK from it.
- The outbox column list is core's, not local. If you change it, you are
  changing a contract.
- **There is one outbox.** `app/models/outbox_event.rb` is it, for every
  producer in this service. A webhook publishes through `OutboxEvent.publish!`
  like a model callback does; a second table, a second envelope builder or a
  second `to_envelope` is a second answer to a question a consumer asks once.
- The publisher loop that moves rows to NATS **does not exist yet**. Until it
  does, `published_at` is always null, `attempts` always zero, and nothing
  consumes these events. Do not write a row and call it delivered.

## Webhooks in

A processor's event arrives signed, is stored verbatim, is acted on at most
once, and leaves as one of this service's own events. The rules:

- **The signature is over the raw bytes.** `request.raw_post`, never `params`
  and never a re-serialized parse — the digest is computed over
  `<timestamp>.<raw body>`, so a re-serialization produces a different digest
  and rejects every real delivery. `Stripe::Webhook.construct_event` does the
  verification; nothing here re-implements the scheme.
- **An unverified body is stored nowhere.** It is not an event, and writing one
  would put an attacker's JSON in the row a human reads when something is wrong.
- **`stripe_event_id` is UNIQUE, and that index is the correctness mechanism**,
  not a query aid. `ProcessorWebhook.ingest` turns the resulting conflict back
  into a lookup, so two concurrent deliveries of one event produce one row.
- **The outbox row and the `processed_at` that marks the delivery finished are
  one commit.** If they were two, a process that died between them would leave a
  row that looks unfinished with the event already published, and the next
  delivery would emit a *second* `billing.payment.succeeded` with a second
  envelope id for one charge. Do not move `handled!` out of the transaction.
- **A replay, an unknown type, a deliberate ignore and a failed mapping are all
  200.** Each is recorded and terminal, and a retry reaches the identical
  outcome. A 5xx teaches a processor to retry a decision already made, and hides
  a parked row behind a timeout. `processor_webhooks.error` is the record:
  `ignored:<reason>` for a decision, `failed:<class>: <message>` for a row
  parked for a human, NULL `processed_at` for the one state a crash leaves.
- **A missing signing secret is a 503, not a 400.** It is our
  misconfiguration and saying the signature was invalid sends an operator
  looking in the wrong place. The cause is logged; the body says only
  `unavailable`.
- **Nothing here is token-authenticated, and nothing here may become so.** The
  sender is a processor, not a cafaye client. A `Bearer` on this path would be a
  second, weaker trust path to the same door.
- The webhook is **not** the state. Nothing here writes a subscription or a
  payment; it writes the receipt and the event. The tables for that are a later
  packet, and until they exist `subject` is the processor's own id — recorded as
  a DECISION in `cafaye.yml`, and changed by one line in
  `Webhooks::StripeEvents.subject_for`.

## Testing

- Tests are written **first**, and shown failing before the implementation.
- **Clocks are injected, never read.** `travel_to(frozen_now)` and derive the
  expected string from `TestSupport::FrozenClock::NOW`. An assertion containing
  a wall-clock timestamp is a test that fails on a different day than it was
  written. Production code calls `Time.current`; that is the seam.
- A test that creates rows to assert on *ordering* gives each row its own
  instant. Otherwise the order falls to the uuid tiebreaker, which is random, and
  "newest first" becomes an assertion about uuid generation.
- No sleeps, no raised retries, no loosened assertions. A flaky test is
  attributed before it is fixed: failing test → can this diff reach that
  surface → measure the baseline at a clean HEAD.
- The database-down path is exercised for real, not asserted about: fake the
  leased connection with `with_lease_connection` in `test/test_helper.rb`.
  minitest 6 removed `Object#stub` (it moved to the `minitest-mock` gem, which
  this service does not depend on), so that helper wraps the stub registry
  ActiveSupport already ships. Do not reintroduce the removed API.
- A contract check against `core` reads core's files rather than paraphrasing
  them, and compares **behaviour** rather than text. Comparing a `Regexp#source`
  to a pattern string looked equivalent and was not: Ruby's regexp optimiser
  reports different sources for the same pattern in different processes.
- Raising a threshold is allowed. Lowering one, or adding an inline lint
  disable to make a build green, is not.
- A gap that cannot be closed in this worktree is recorded in code, not skipped
  quietly — see `PENDING_CORE_CATALOG_ROWS` and `PENDING_PAYLOAD_ALIGNMENT` in the
  contract spec. Both are asserted **as sets**, not subtracted from the failures:
  subtracting would let a payload that starts matching sit there forever.
- A webhook spec posts **committed fixture bytes**, signed with a constant that
  is a credential for nothing, and asserts against the real verification path. No
  network, no stubbed verifier. The fixtures' `created` timestamps are what the
  event-time assertions are derived from, so a fixture edited without its tests
  failing is a fixture nobody looked at.

## Conventions

- **Never** edit `Gemfile.lock` as a side effect. A lockfile change is its own
  commit with its own reason. `bin/prime` only ever runs `bundle install`.
- **Never** copy code from `moon/refs/` into this repository. `jumpstart-pro` is
  a licensed product and the shallow clones are behavioral references only;
  every line here is written from scratch (PLAN §2).
- **Never** add a gem without saying so in the PR body. Rails defaults and `pg`
  are the current floor; a new dependency is a decision, not a convenience.
  (This is why there is no JSON Schema validator, no outbox gem and no HTTP
  client: each would have been one, and each was refused.)
- Errors are raised at the boundary with the identifier needed to find the
  failing row, not just a message — and a failure message never returns to an
  HTTP caller. `/readyz` logs the database error and answers a generic 503, and
  `Problem::INTERNAL_DETAIL` is a constant for the same reason.
- Every non-2xx is `application/problem+json`, built by `app/lib/problem.rb`.
  Never render an error body any other way, and never let Rails render one:
  `config.exceptions_app = routes` is what makes a 404 on an unknown path and a
  500 on a bug problem+json too.
- `rescue_from` runs *outside* the `after_action` chain. Anything a rescue
  handler renders must set its own headers — this is why `render_problem` calls
  `set_trace_id_header` and does not rely on the callback.
- Rails `enum` is not used on request-shaped columns. It raises `ArgumentError`
  on an unknown value, which at an HTTP boundary is a 500 for something the
  client got wrong. Use an inclusion validation plus a `CHECK` constraint: the
  database still refuses what the model would not have written, and the client
  gets a 422 naming the field.
- Migrations do not read model constants. Inline the literal, so the migration
  keeps meaning what it meant the day it ran.
- A column named `type` is single-table inheritance on any Active Record model.
  `processor_webhooks.type` is the processor's own type string, so the model sets
  `self.inheritance_column = nil`. That line is load-bearing, not tidiness:
  without it every `find` on the table tries to resolve
  `customer.subscription.updated` to a class and raises.
- Time is UTC, and stored `timestamptz` where the column is an instant. IDs are
  opaque strings. `db/schema.rb` is committed.
- A webhook's event carries the **processor's** timestamp in `time`, not the
  moment this service wrote the row. `OutboxEvent.publish!` takes `time:` for
  exactly this; a model callback omits it and gets `Time.current`. An event
  stamped on arrival makes out-of-order delivery undetectable, because every
  event then appears to have happened in the order it arrived.

## Contracts

- The two probes are infrastructure, not contract surface. They are not in
  `cafaye.yml`'s `exposes` and must not grow query parameters, auth, or a
  versioned payload — an uptime monitor is the only reader.
- `openapi/v1.yaml` is the HTTP contract, `/v1` on every path and `info.version`
  present (core v0.2, D4). `cafaye.yml`'s `exposes.api` points at it, and
  `test/contract/` fails if the file is not there.
- Every endpoint and event this service publishes is validated against `core`'s
  specs in `test/contract/`. Never hand-write a response shape the OpenAPI
  document does not describe.
- **`/v1` is unauthenticated in v0.** No endpoint reads a token because core's
  JWKS verification is not in this repository yet, so `GET /v1/customers`
  returns every customer. This is a recorded gap, not a design: do not expose
  the surface to anything but the gateway, and do not build on it.
- **`/v1/webhooks/stripe` is the one authenticated path, by signature.** It
  authenticates the *processor*, not a cafaye client, and it is declared in
  `openapi/v1.yaml` under the `webhooks` tag with its own `200`/`400`/`503`
  responses. Its dedupe key is the processor's event id enforced by a unique
  index, not an `Idempotency-Key` header, and it takes no query parameters. A
  test asserts the manifest's `exposes.api` document declares the path that
  `config/routes.rb` serves.
- Every event type the webhook mapping can produce is in `OutboxEvent::TYPES`
  and in `cafaye.yml`. A type that is not would be refused at the write, from
  inside a processor request, and answered 200 — an outage visible only in the
  processor's dashboard. `test/contract/` and the webhook specs both assert it.
- **`billing.subscription.started` does not satisfy core's payload schema** for
  this build, and the exact difference is in `PENDING_PAYLOAD_ALIGNMENT` in the
  contract spec. Core's schema wants `pln_…` and `acc_…` ids this service does
  not have. The event is published anyway — the catalog row exists and the
  envelope is core-shaped — and the gap is a decision recorded in `cafaye.yml`
  for the manager, not a silent skip.
- Breaking a contract is a major version plus a migration note in `README.md`
  and `CHANGELOG.md`, reviewed by a human — not a patch.

## Before you open a PR

- [ ] `bin/prime` is green from a clean worktree
- [ ] New behavior has a test that fails without it
- [ ] Money changes keep 100% line and branch coverage on `money.rb`
- [ ] Anything published is in `cafaye.yml`, in `OutboxEvent::TYPES`, and in
      core's catalog — or the gap is written down in both places
- [ ] Lint and security scans are green, and nothing was disabled to get there
- [ ] `AGENTS.md` still describes the repository as it now is
- [ ] `CHANGELOG.md` has an entry
