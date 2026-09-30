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

Three packets, in order.

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
  `billing.payment.succeeded|failed` — into **billing-02's** outbox.
- **billing-04** is the subscription lifecycle: the `subscriptions` table, the
  state machine that decides which transitions are possible, the `/v1`
  endpoints that buy a subscription and cancel one and move it between plans,
  and the three requests this service now makes *to* Stripe.
- **billing-05** is a reconciliation and nothing else: core shipped payload
  schemas for all eight published types and raised D10, and
  `test/contract/outbox_envelope_contract_test.rb` was the thing that noticed.
  No behaviour in `app/` changed except one comment. What it found is written
  down in `cafaye.yml` as a DECISION NEEDED — core's subscription schemas
  describe the payload billing-03b emitted, and billing-04 moved those events
  onto billing's own ids.
- **billing-07** is the document and the router, held to each other: one test
  that compares `(method, path)` in both directions, replaces a path-only
  comparison that could not see a verb, and found one operation
  (`PUT /v1/customers/{id}`) that was served and in no document. It removed that
  route rather than documenting it. No behaviour in `app/` changed.
- **billing-09** is a **duplicate-charge race and the constraint that closes it.**
  `Ingestion#call` was a check followed by an act, and two concurrent deliveries of
  one event id both read `handled?` as `false`, both emitted, and one Stripe event
  became two `billing.payment.succeeded` rows — two envelope ids, which core defines
  as the dedupe key, so a consumer cannot tell the duplicate from new information
  about money. A partial unique index over the outbox's `processor_event_id` makes
  the duplicate impossible under **any** interleaving, and a lost race is recorded as
  `ignored:duplicate_delivery` rather than parked as a failure. The regression test
  manufactures the interleaving with a two-party barrier — no sleep anywhere — and
  the property is shown to rest on **more than one constraint**, because a start
  payload deliberately carries no `processor_event_id`. The packet also found three
  test helpers delivering under an event id their own payload did not carry, which
  the new index turned from a silent lie into a loud failure, and a ~5% flake in
  which a losing delivery was parked as a failure because a model validation won
  the race instead of the index. See `REPORT-billing-09.md`, which also says what
  was not fixed.
- **billing-08** is hardening, and it is where the *recorded* gaps stop being
  prose. `test/contract/tenant_isolation_matrix_test.rb` enumerates every `/v1`
  operation the router serves and requires each one to be classified account-scoped
  or not, with a reason — so a route added tomorrow fails by name instead of
  joining an unauthenticated surface nobody decided the scope of.
  `test/integration/secrets_do_not_leak_test.rb` captures real log output from
  the **failure** paths and asserts a processor key, a signing secret and a
  customer email are absent from it, because no static analyser in the fleet
  finds a secret leaked at runtime. The controller stopped answering **500** to a
  signed body that is valid JSON but not an object — an array, a number, a
  string, a boolean or `null` — where the endpoint's own status table says a 5xx
  never is an answer. And the lifecycle's stale-delivery guard above landed here.

  Two judgement calls are recorded because they are the kind that rot. The
  tenant matrix asserts every entry is `unscoped` **as a set of the distinct
  verdicts**, not as a count, so the day a route is genuinely scoped the failure
  names the verdict that changed; and every entry carries a reason that is
  asserted to be non-empty, because `/v1/subscriptions` returning every row is a
  gap that arrived by nobody writing it down.

billing-05 changes a claim the earlier packets made, so it is stated plainly:
**this service now talks to Stripe.** It did not, and saying so was true when it
was written. A subscription is bought through a Checkout Session, cancelled by
asking Stripe to cancel, and moved between plans by asking Stripe to move it; a
lifecycle that cannot make those three requests is not a lifecycle. The claim
that replaces it is narrower and checkable by reading one file: **every request
this service makes to Stripe is one of the three methods on
`Processor::StripeClient`, and there is no other `Stripe::` call in the
repository.** No new dependency — the `stripe` gem was already here, for
`Stripe::Webhook.construct_event`.

There are no invoices, no usage metering, no prepaid credit and no publisher
loop yet. Do not read their absence as something to fix in a side patch; those
are later packets with their own briefs.

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
│   │   ├── v1/                        # customers, plans, subscriptions
│   │   └── webhooks/                  # signed inbound, from a processor not a client
│   ├── lib/
│   │   ├── problem.rb                 # the one error shape
│   │   ├── money_params.rb            # the only place a request becomes an amount
│   │   └── identifiers.rb             # the uuid shape, in one place
│   ├── models/
│   │   ├── money.rb                   # the money primitive
│   │   ├── customer.rb                # owner_type + owner_id, one per processor
│   │   ├── plan.rb                    # price is a Money or it is not a price
│   │   ├── subscription.rb            # a status this service did not decide
│   │   ├── processor_webhook.rb       # what a processor sent, stored once
│   │   └── outbox_event.rb            # the event, and the envelope it becomes
│   └── services/
│       ├── processor/
│       │   └── stripe_client.rb       # the three requests this service makes
│       ├── subscriptions/             # the lifecycle, as three pure objects
│       │   ├── state_machine.rb       # which transitions are possible
│       │   ├── plan_change.rb         # when a move takes effect
│       │   └── lifecycle.rb           # the only writer of a subscription
│       └── webhooks/                  # verify, store, normalize, emit — in that order
│           └── ingestion.rb           # store, act once, and what a lost race records
├── test/
│   ├── contract/                      # the checks against core, and the HTTP one
│   │   ├── http_surface_contract_test.rb # the document and the router, by method and path
│   ├── coverage/                      # the money-path coverage gate, and its inventory
│   ├── integration/                   # health, and the webhook's HTTP edge
│   ├── models/                        # minitest, table-driven
│   │   └── outbox_processor_event_id_migration_test.rb # reversibility, run for real
│   ├── requests/v1/                   # the API specs
│   └── services/                      # the lifecycle, the client, the webhook mapping
│       └── webhooks/
│           └── concurrent_delivery_test.rb  # the duplicate-charge race, deterministically
├── .github/workflows/ci.yml           # calls kit's reusable workflow, plus the gate
├── CHANGELOG.md                       # every notable change, per Keep a Changelog
└── REPORT-billing-09.md               # the race: evidence, fix, and what was not fixed
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
| Everything CI runs | `bin/prime`, plus `bin/bundler-audit check --update` and `bin/brakeman --no-pager --quiet --exit-on-warn` (`mise run security`) |

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

- **No amount is ever computed to send to a processor.** A plan change sends a
  `proration_behavior`; a cancellation sends an id and a boolean. The credit for
  an unused period is the processor's, and a figure calculated in Ruby and sent to
  Stripe would be a figure this service did not keep — the two would eventually
  disagree, in a customer's invoice. `Processor::StripeClient` has no accessor
  for a credit, a refund or a prorated amount, and the specs assert the *absent*
  keys as well as the present ones.

### The gate on the money paths

Money paths are held to **100% line and branch coverage** (PLAN §3), measured
with Ruby's standard library `Coverage` so the gate costs no gem. Two files are
in the list: `app/models/money.rb` and `app/services/subscriptions/plan_change.rb`
— the primitive, and the only place in the repository that *compares* two
amounts.

Four things about how that gate runs are not incidental, and each was a bug first:

- **`Coverage.start` runs before the application boots, and the app is
  eager-loaded inside the measurement window.** Measuring from inside the minitest
  process reports a file as covered when the corpus merely autoloaded it, because
  `Coverage` records only what executes after it starts. A gate that passes for
  the wrong reason is worse than no gate.
- **The measurement runs in a subprocess**, with a report path unique per run.
  The suite runs in parallel, and two workers sharing one path would read each
  other's coverage — one of them asserting numbers that belonged to a different
  corpus.
- **The gate's honesty is asserted.** `test/coverage/money_paths_coverage_test.rb`
  measures a corpus that reaches almost nothing and requires it to be *reported*
  uncovered, and requires a full corpus and a minimal one to differ.
- **The list itself is checked against the repository.**
  `test/coverage/money_path_inventory_test.rb` partitions every file under `app/`
  that touches money into "is a money path" and "has money in it", so a new money
  path cannot be added ungated. The second group carries a *reason* that is
  asserted to still hold, and its money entry points are asserted behaviourally —
  so "not in the gate's list" never quietly comes to mean "not covered". A file
  that contradicts its reason belongs in the first group or in neither.

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
- **A subscription event's type is derived from what the delivery did to the
  row**, not from which processor event carried it. This is the one place the
  "same type, same vocabulary" rule needs explaining rather than restating, and
  it is what makes out-of-order delivery safe.
- The publisher loop that moves rows to NATS **does not exist yet**. Until it
  does, `published_at` is always null, `attempts` always zero, and nothing
  consumes these events — including courier, which is how
  `billing.subscription.started` and `.canceled` become transactional mail. Do not
  write a row and call it delivered.

## Subscriptions

The lifecycle is three objects, and which one you are editing tells you which
rules you are about to break.

- **`Subscriptions::StateMachine`** is pure: a from-status and a to-status in, an
  answer out, no database and no clock. **The whole legal/illegal grid is one
  table**, so the set of *impossible* transitions is readable rather than inferred
  from conditionals. There is one rule and everything else is ordinary code:
  **`canceled` is terminal, and nothing leaves it.** A status the processor uses
  and this service does not model is refused by the constructor — a row that said
  `active` for a subscription the processor calls `incomplete` would grant
  entitlements nobody paid for.
- **`Subscriptions::PlanChange`** compares two prices and decides when a move
  takes effect. An upgrade is invoiced immediately; a downgrade or a lateral move
  lands at the renewal. Cross-currency and cross-interval comparisons are refused
  rather than guessed. It has no amount in it at all.
- **`Subscriptions::Lifecycle`** is the **only** writer of a subscription's state
  and the only thing that emits its events. There is no `after_update` on
  `Subscription` and no branch of the API that changes a status. Do not add one:
  the processor is the party that can bill, and a local row that disagreed with it
  would grant entitlements nobody is paying for.

Two rules that are not obvious and that the specs exist to hold:

- **A deletion arriving before its creation creates a `canceled` row.** It is the
  only statement about that subscription that has arrived, and dropping it would
  leave an *active* row — and an active row grants entitlements — for something
  the processor says is gone. The `created` that follows is then refused by the
  terminal rule. billing-03b published both events and left the active row; that
  was the bug this rule fixes.
- **A delivery that changes nothing is refused, not published.**
  `no_change_to_record` — otherwise a processor that repeats itself under a fresh
  event id produces updates that carry no update, and a consumer counting plan
  changes stops meaning anything.
- **A delivery that predates the one that last wrote the row is refused.**
  `stale_delivery`. The state machine's rule is about a *pair* of statuses and
  covers the one order this service knows for certain. Everything else is a
  *sequence*, and the processor does not promise delivery order, so a
  `customer.subscription.updated` the processor retried an hour late lands on a
  row it has already moved past. `last_processor_event_at` records the
  processor's own timestamp for the delivery that last wrote the row, and a
  delivery **strictly older** than it is refused — *strictly*, because those
  timestamps are epoch seconds, two genuinely different events routinely share
  one, and refusing those would drop real deliveries. A row with no recorded
  timestamp has nothing to be stale against, which is the case a deletion
  arriving before its own creation depends on. Without this, a `past_due`
  subscription whose charge failed becomes `active` again, which grants
  entitlements nobody is paying for, and a late `cancel_at_period_end: false`
  tells every consumer a cancellation was called off.

  **This is not the same guarantee as at-most-once, and neither replaces the
  other.** `stale_delivery` refuses a delivery that arrived *late*; two
  deliveries of *one* event id that arrive *together* are both current, both
  pass it, and only the outbox's unique index on the processor event id
  separates them. See "Webhooks in" below.

Every refusal raises `Subscriptions::Refused`, which the webhook layer records as
`ignored:<reason>` and answers 200. The reasons are part of the contract:
`unknown_customer`, `unknown_plan`, `no_subscription_to_update`,
`canceled_is_terminal`, `no_change_to_record`, `stale_delivery`.

## Webhooks in

A processor's event arrives signed, is stored verbatim, is acted on at most
once, and leaves as one of this service's own events. It may also *write*: a
subscription event applies to the subscriptions table, inside the same
transaction that marks the delivery finished. The rules:

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
- **The UNIQUE index on that row is not, by itself, at-most-once — and the gap
  between the two cost this service a duplicate charge.** It makes two concurrent
  deliveries of one event id agree about *which row* they hold; it does not make
  them agree about the answer. `Ingestion#call` reads `handled?` and then acts,
  and `handled?` reads a column neither thread has written yet, so under READ
  COMMITTED both read `nil` and both emit.
  **At-most-once therefore rests on a second constraint, in the outbox:**
  `outbox_events_processor_event_id_idx`, a partial unique index over
  `((data ->> 'processor_event_id'))` where that key is present. It is an index
  over an existing column and not a new one **because the outbox column list is
  core's contract** — core's `docs/event-outbox.md` says "the column list is the
  contract", and the key is already in `data` because `provenance` puts the
  processor's own id in every webhook-emitted payload.
  A duplicate refused by that index is recorded as `ignored:duplicate_delivery`,
  **not** as `failed:` — the event exists, written by the request that won, and
  parking it would put a row in front of a human for a correct event.
  And the property is **more than one constraint, and not on this table alone**:
  a start payload deliberately carries no `processor_event_id`, so a duplicate
  `customer.subscription.created` never reaches the outbox index — the second
  `INSERT` into `subscriptions` is refused first. **Which** refusal is a
  scheduling accident, not a fact to write down: `subscriptions` carries a
  uniqueness *validation* on `processor_subscription_id` in the model and a
  unique *index* over the same column, and either thread can be refused by
  either. Measured on this branch over 60 barrelled duplicate creations: **57
  refused by the index, 3 by the validation.** Neither is individually
  sufficient to reason about — dropping either one alone still prevented the
  duplicate, while dropping *every* index on `subscriptions` reopened it (two
  subscription rows, two `billing.subscription.started` events). So the honest
  statement is that the duplicate is prevented as long as the model's validation
  and the table's index are both there, and the ingestion layer is therefore
  written against the **exception**, not against a named constraint.
- **A uniqueness failure and a unique-index violation are one fact, and
  `Ingestion` classifies them as the decision they are** —
  `ignored:duplicate_delivery`, answered 200, never `failed:`. Before this, 3
  deliveries in 60 were parked for a human over an event that was published and
  perfectly correct, purely because a validation won the race instead of an
  index. The classification is on the *error* (`:taken`), not the exception
  class, because a `RecordInvalid` with no uniqueness error in it is a bug in
  this service and still belongs in front of a human —
  `ingestion_test.rb` holds both directions as their own tests, so widening the
  rescue into a blanket one fails rather than being argued about.
- **A delivery's id and the payload that arrived with it are one value.**
  `stripe_controller.rb` passes `event_id: payload["id"]`, and
  `Webhooks::StripeEvents.provenance` reads that same field to stamp the emitted
  event, so in production the two cannot disagree. A test helper that varies the
  delivery's id while leaving the body's id at the fixture's is arranging a state
  Stripe never sends — and the outbox index above makes it fail loudly instead of
  publishing two events that both claim to be the same one. Three helpers did
  this; the one-line merge is in each, and a test pins the invariant.
  `test/services/webhooks/concurrent_delivery_test.rb` holds all of it, and
  `AGENTS.md`'s rule on concurrency tests below is written because of it.
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

## CI

`.github/workflows/ci.yml` has four jobs, and **the job names are the claims** —
a green tick over unnamed steps is a green tick over an unknown amount of work,
and in this repository the unknown is load-bearing.

| job | what it is |
|-----|------------|
| `ruby (kit)` | `uses: cafaye/kit/.github/workflows/ci.reusable.yml@master` with `language: ruby`. The shared half. Fails on two steps, absorbed by `continue-on-error` — see below. |
| `gate` | THE gate. `bin/prime` against a real Postgres, every environment-gated tier forced on and counted, and `git diff --exit-code`. |
| `security` | `brakeman` and `bundler-audit`, with no database. |
| `pins` | One Ruby number in three files, the documented `uses:` path, and no secret in the file. No toolchain, so it fails in seconds. |

Four things that are not obvious and that the file argues in full:

- **`bin/prime` is the gate, in CI and locally.** Not a hand-assembled list of
  its four steps. A shared workflow that retyped them would be a second gate, and
  a second gate is a second thing to be wrong.
- **A caller cannot give a reusable workflow a database.** GitHub allows only
  `name`, `uses`, `with`, `secrets`, `strategy`, `needs`, `if`, `concurrency`
  and `permissions` on a job that calls one, so `services:` is unreachable from
  a caller. That, and the tier counts and the lockfile, are why the companion
  jobs exist at all.
- **`ruby (kit)` fails on two steps, and `continue-on-error` absorbs them.**
  `bundle exec rake` is `rails test` and kit's `ruby` job declares no service
  container, so it dies with `ActiveRecord::DatabaseConnectionError`; and
  `bundle exec rake coverage` is a task this service does not have and should
  not want, because the coverage gate here is `MoneyPathsCoverageTest` and it
  runs inside `bin/prime`. Both errors are reproduced in the file's header.
  The failures are visible and non-blocking, and `gate`, `security` and `pins`
  are the required checks — a job that is expected to be red and is not marked
  for it makes the whole workflow red, and a workflow that is always red is one
  whose red means nothing. `continue-on-error` outlives the gap only if nobody
  deletes it, so the condition for retiring it is written into the file: kit's
  `ruby` job grows a `services`/`env` seam, **and** `rake coverage` exists here
  or kit stops running it.
- **The suite size is held by equality, not as a floor.** `823 runs / 2299
  assertions / 0 skips` is the number asserted at the top of the workflow on this
  branch. master at `e63bb7a` was `763 / 2100`; the difference is billing-08's
  hardening and billing-09's race fix, itemised in the workflow's own header so a
  reviewer does not have to reconstruct it.
  A floor would accept a suite that lost 200 tests, and the tests it would lose
  first are the money arithmetic and the webhook signatures. Adding a test turns
  CI red until
  `BASELINE_RUNS`/`BASELINE_ASSERTIONS` are raised **in the same commit** — that
  is the intended direction, and lowering one is not.

### The tier that skips without you noticing

`test/contract/outbox_envelope_contract_test.rb` reads core's real schemas and
**skips every test in the file** when it cannot read them, printing
`skip("core is not on disk; set CORE_PATH to …")`. Measured on this branch, same
commit, same code, with `CORE_PATH` pointed at a checkout and then at nothing:

| `CORE_PATH` | `test/contract` (the tier) | whole suite |
|---|---|---|
| a core checkout | 45 runs, 400 assertions, 0 skips | 823 runs, 2299 assertions, 0 skips |
| pointing at nothing | 45 runs, 61 assertions, **19 skips** | 823 runs, 1956 assertions, **20 skips** |

**Same run count, same exit code, and 343 assertions of contract checking simply
not done.** A green run that did not notice would have reported "the outbox
contract holds" while having checked nothing at all. The whole `test/contract`
directory is the tier; it is named as a directory rather than a file list because
billing-07 moved three tests into `http_surface_contract_test.rb` and a file list
read that relocation as a deletion — and because billing-08 added
`tenant_isolation_matrix_test.rb`, which does not read core at all and therefore
must not be reachable through a path that skips.

A second test reads core and did not say so: `subscription_delivery_test.rb`
asserted against `Rails.root.join("..", "core")` with no seam at all, so a
developer with the repositories side by side passed and **a CI runner raised
`Errno::ENOENT` before asserting anything**. It reads `CORE_PATH` now, and
`gate` sets that variable on the job rather than on one step, because a variable
set per step is a variable the second reader does not get.

So:

- **locally**, a `19 skipped` in the contract tier, or a skipped test named
  "both events courier needs have a row in core's catalog", is a missing core
  checkout, not a pass. Put `core` next to this worktree, or set `CORE_PATH`.
- **in CI**, `gate` checks `cafaye/core` out of the repository itself and
  **fails the build on a single skipped test**. `cafaye/core` is public, so no
  token is involved, and the ref is `master` rather than a pinned SHA on purpose:
  this tier exists to catch a change in core, and a pinned ref would blind it.

### The other environment-gated tier

`config/environments/test.rb` sets `config.eager_load = ENV["CI"].present?`.
GitHub Actions always exports `CI`, so the suite eager-loads the whole
application in CI and not locally — which means "the application loads" is
checked in CI by an *implicit* convention. `gate` sets `CI` explicitly and has a
step that fails if `config.eager_load` is false, or if `eager_load!` loaded
fewer files than `app/**/*.rb` contains (38 on this commit).

### Secrets

No processor key is in the repository, in CI configuration, or in any log. The
suite generates its own Stripe signing secret per run
(`StripeWebhookHelpers::WEBHOOK_SECRET` in `test/test_helper.rb`, a credential
for nothing) and talks to `FakeStripeAPI`, never to Stripe. The `gate` job
asserts `STRIPE_API_KEY` and `STRIPE_WEBHOOK_SECRET` are absent from the
environment, and the `pins` job fails the build if the workflow file ever gains a
`${{ secrets.… }}` reference, a Stripe key, a signing secret or a PEM header.

## Testing

- Tests are written **first**, and shown failing before the implementation.
- **A tripwire that has never been seen red is a check that has never been
  tested.** Every drift check here is proven by a mutation that makes it fail and
  by the output that says so — and the mutation is reported, because "I broke it
  on purpose and it noticed" and "I think it would notice" are different claims.
  The direction of the failure matters too: a comparison that stops at the first
  of two directions hides the second behind it, and one of the two is often the
  one that finds the bug.
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
- **A concurrency test manufactures its interleaving; it never waits for one.**
  Two threads doing the same thing at the same time is a *probable* race, and a
  test asserting a probable outcome is a flake generator that passes on a fast
  machine and fails on a loaded one. The window is entered on purpose: a
  two-party barrier (`Mutex` + `ConditionVariable`, **no timeout** — a timeout
  here is a sleep with a nicer name, and it turns a deadlock into a flake) holds
  both threads inside the check-then-act window until both have arrived.
  Three things this repository has already had to learn, all of them from
  `test/services/webhooks/concurrent_delivery_test.rb`:
  - **A thread's commit does not invalidate the main thread's query cache.**
    Active Record's cache is on in the test environment, cleared between tests
    but *not within one*, and every count is taken on the main thread after the
    workers committed. Counts came back stale — `0` for a table holding a
    committed row. The cache is dropped once, after the last commit, and counts
    read through `uncached`.
  - **`prepend` cannot be undone.** A file-scope `prepend` in a test changes
    every other test in the suite for the rest of the run; install a gate with
    `alias_method` on the class and restore it in `ensure`.
  - **Running a migration commits the enclosing transaction**, so a
    reversibility test inside a transactional test class makes its own rows
    durable and breaks unrelated tests. It gets its own file.
- **Threads need their own connections, so the test that uses them cannot be
  transactional** — it would assert against an empty database while the workers
  wrote real committed rows. The cost is rows that outlive the test, so the
  teardown clears every table the path writes, in both directions (children
  before parents), and the list of tables is written down rather than left as a
  blanket truncation. Two classes in this repository do this, each for a stated
  reason.
- The database-down path is exercised for real, not asserted about: fake the
  leased connection with `with_lease_connection` in `test/test_helper.rb`.
  minitest 6 removed `Object#stub` (it moved to the `minitest-mock` gem, which
  this service does not depend on), so that helper wraps the stub registry
  ActiveSupport already ships. Do not reintroduce the removed API.
- A contract check against `core` reads core's files rather than paraphrasing
  them, and compares **behaviour** rather than text. Comparing a `Regexp#source`
  to a pattern string looked equivalent and was not: Ruby's regexp optimiser
  reports different sources for the same pattern in different processes.
- **A validator that skips a constraint it does not understand reports "no
  problem" for a document it never checked.** That is the failure a contract test
  exists to prevent, so the payload validator in `test/contract/` has a closed
  vocabulary — `UNDERSTOOD_KEYWORDS`, `JSON_TYPES`, `UNDERSTOOD_FORMATS` — and
  raises on anything outside it. A drift test walks every keyword core actually
  uses and fails once, by name, when a shape appears the validator does not model.
  Do not widen a check into a `rescue`, and do not turn the raise into a `return
  true`: a breach reported as clean is worse than a breach reported as a crash.
- **A recorded-debt table may never become the thing being iterated.** An empty
  table exits 0 having checked nothing, which is a skipped test in everything but
  name. Every table in `test/contract/` is therefore *derived* from core's files
  and compared, so the work is over core and not over the constant.
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
  failing is a fixture nobody looked at. `construct_event` appears nowhere under
  `test/`, and the `gate` job in CI fails the build if it ever does.
- **`rails test` runs in parallel workers, and each worker gets its own
  database.** `test_helper.rb` calls `parallelize(workers: :number_of_processors)`,
  so a run creates `<database>_0` … `-7` beside the base database and eight
  workers never share one. The number of workers changes the wall clock and
  nothing else — the same tests and assertions with one worker or eight, verified
  both ways on this packet — which is why the gate counts tests and never
  seconds.
  What parallel workers do **not** protect against is two `rails test` processes
  in the *same* worktree — they race on the same per-worker databases, and a
  per-checkout database name separates worktrees from each other, not processes
  from each other. One checkout, one suite.
- **A worker that dies abnormally makes the suite hang, not fail.** Rails runs
  the parallel workers over DRb and
  `ActiveSupport::Testing::Parallelization::Server#shutdown` waits with
  `while active_workers?; sleep 0.1; end` for each one to deregister. A worker
  killed before it can deregister is never reaped and the parent spins in that
  sleep at teardown — **after** printing the summary line. So a green
  `823 runs, 0 failures` summary followed by nothing is that, not a pass.
  Nothing
  suppresses it: the job times out and goes red, and the count guard never
  runs. Do not "fix" it with retries; find the worker that died.

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
- **A partial unique index is a statement about a set of statuses, and it is
  tested behaviourally.** `subscriptions` is unique on `(account_id, plan_id)`
  *where the subscription is live*, because `canceled` is the only terminal status
  and a customer who cancels and returns has to be able to subscribe to the same
  plan again. Comparing the index's predicate to a string in the model would prove
  two texts agree, which is not the same fact; the specs insert two rows per
  status pair and ask whether the database objects.
- **A `uuid` column casts before a validation sees it.** `"not-a-uuid"` assigned to
  a `uuid` attribute becomes `nil`, so a shape validation on such a column is
  unreachable code that reads as if it were doing something. `Subscription#account_id`
  deliberately has none, and the presence validation is what reports the problem.
  (`Customer#owner_id` has one and it is equally unreachable — noted, not changed:
  it is not this packet's model to refactor.)
- **Every problem in a request body is reported at once.** A client that sent
  three wrong fields gets three failures, not the first one three times. That is
  why `V1::SubscriptionsController#refuse` *records* and the action renders once,
  and it is the same rule `render_validation_failure` already follows for a
  model's own errors.
- **A processor's message never returns to a caller.** It is logged with the
  identifier that was refused, and the body says only what this service knows: a
  503 for a processor it cannot reach, a 422 naming the plan. The processor's
  internal text is the processor's to decide who sees it.
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
  JWKS verification is not in this repository yet, so `GET /v1/customers` and
  `GET /v1/subscriptions` return every row, and `POST /v1/subscriptions` takes a
  `customer_id` in the body. This is a recorded gap, not a design: do not expose
  the surface to anything but the gateway, and do not build on it. Which is also
  why a `User`-owned customer is refused by that endpoint — which account a user
  belongs to is identity's fact, and no event carrying it is in this build's
  `consumes`.
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
- **The three subscription events are published in a shape core's payload schemas
  reject, and that is recorded rather than matched.** core-03 shipped a payload
  schema for all eight types. For `billing.plan.*` this service now satisfies
  them except for `entitlements`, which core's plan schema does not name. For
  `billing.subscription.*` the disagreement is larger: core's D10 rewrote those
  three schemas on the grounds that "billing has no subscriptions table", which
  was true of billing-03b and stopped being true when billing-04 added one and
  moved the events onto billing's own ids. They are recorded in
  `PENDING_PAYLOAD_ALIGNMENT` and asserted in **both** directions, and named as a
  DECISION NEEDED in `cafaye.yml`. Do not "fix" this by editing the payload:
  matching core means either emitting a payload no consumer has agreed to or
  dropping `plan_id` and `account_id`, which are the two fields that make a
  subscription event actionable. core owns the change; see core's own D10, which
  names it as the second breaking change.
- **`PENDING_ID_PATTERNS` is empty, and the test that held it is derived.**
  core's D10 removed the `sub_…` / `pln_…` / `acc_…` patterns, so a field core
  does not constrain has no unclosed gap against it. The table may not become the
  thing that is iterated: a table iterated zero times exits 0 having checked
  nothing, so the contract test *derives* the gap from core's files and compares.
  New debt goes in the table; the assertion reads core, not the table.
- **`billing.subscription.updated`, not `.changed`.** The action vocabulary in
  core's `docs/event-naming.md` is a closed list for v0 and `changed` is not on
  it; `billing.subscription.updated` is, and it is already in core's catalog. The
  vocabulary core has fixed is the vocabulary used here. If the manager disagrees
  it is one constant, `Subscriptions::Lifecycle::UPDATED_EVENT`, and a catalog
  row agreed first.
- **Every `(method, path)` in `openapi/v1.yaml` is served, and every
  `(method, path)` the router serves is in the document or named with a reason.**
  `test/contract/http_surface_contract_test.rb` compares the two as sets, in both
  directions, so an operation added to one and not the other fails **by name**
  rather than describing an API nobody can call. Three things about it are not
  incidental:
  - **It is keyed by method as well as path.** The check it replaced compared
    paths and filtered the router with `start_with?("/v1")`, so `resources`'
    two verbs for one `update` — `PATCH` and `PUT` — were one path on each side
    and it reported agreement. `PUT /v1/customers/{id}` was served, and in no
    document.
  - **The exclusions are named, not filtered.** Every route that is not a client
    operation is keyed by method and path with the reason it is not one, and a
    route that is neither declared nor excluded fails. Otherwise the list rots
    silently and grows a `/internal` nobody argued about — and an exclusion for a
    route that has gone away fails the other way, so a stale one cannot quietly
    cover whatever is added at that path next.
  - **It runs without `core`.** `test/contract/outbox_envelope_contract_test.rb`
    skips when `core` is not on disk, and a check behind that skip is not a
    check. The document checks live beside it because they read the document, the
    manifest and the route set, none of which is core.
- **Every operation has an `operationId`, and no `operationId` is used twice.**
  A generator turns these into method names and nothing else, so a duplicate or
  a missing one is a compile error in a customer's language, discovered by them.
  The fifteen are pinned rather than derived, which is what makes a rename fail
  here: the count is not asserted, the list is, so a removal and an addition are
  different failures.
- **An update is a `PATCH`, and there is no `PUT`.** `resources` draws both verbs
  for one action, and a whole-resource replacement is not what any update here
  is: `CustomerUpdate` is closed, and `owner`/`processor` are not updatable at all
  because they are the key the uniqueness rule is built on. `config/routes.rb`
  therefore spells the customer routes out, as it already did for plans and
  subscriptions. Documenting the `PATCH`'s behaviour under a `PUT` would be a
  document lying about its own semantics — which is the thing the check above
  exists to prevent.
- **`info.version` is pinned, not derived.** A non-breaking addition bumps only
  `info.version`, never the `/v1` prefix; core's checklist asks for the bump if
  anything else in the document moved, prose included. A test that read the
  version out of the document and compared it with itself would pass every
  document ever written.
- Breaking a contract is a major version plus a migration note in `README.md`
  and `CHANGELOG.md`, reviewed by a human — not a patch.

## Before you open a PR

- [ ] `bin/prime` is green from a clean worktree
- [ ] New behavior has a test that fails without it
- [ ] Money changes keep 100% line and branch coverage on every file in
      `MoneyPathsCoverageTest::MONEY_PATHS`, and a file that touches money is in
      that list or in `MIXED_MONEY_FILES` with a reason that still holds
- [ ] A new subscription status is added to the state machine's table, the model's
      set, the migration's `CHECK` and the spec that asserts the grid — the test
      that covers every status fails if any of the four is missing
- [ ] Anything published is in `cafaye.yml`, in `OutboxEvent::TYPES`, and in
      core's catalog — or the gap is written down in both places
- [ ] Lint and security scans are green, and nothing was disabled to get there
- [ ] `AGENTS.md` still describes the repository as it now is
- [ ] `CHANGELOG.md` has an entry
