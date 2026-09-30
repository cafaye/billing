# Changelog

All notable changes to billing are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **The outbox contract test now describes the world core shipped in core-03.**
  core added a payload schema for all eight of this service's published types and
  raised **D10**, a breaking spec change that removed the `sub_…` / `pln_…` /
  `acc_…` patterns from `billing.subscription.started`. On billing master with
  the new core, `test/contract/outbox_envelope_contract_test.rb` reported two
  failures and three errors.

  * `PENDING_ID_PATTERNS` is **empty**. D10 closed all three recorded entries from
    the core side: `subscription_id` no longer declares a `pattern`, and
    `plan_id` and `account_id` are no longer declared as properties at all. A
    field core does not constrain cannot have an unclosed gap against it.
  * The two tests that iterated that table no longer do. They **derive** the gap
    from core's files and compare. An empty table iterated zero times exits 0
    having checked nothing, which is the failure PLAN.md §1 forbids, so the work
    is now over core's schemas rather than over a constant.
  * `NO_PAYLOAD_SCHEMA_YET` is **empty**: core-03 answered all eight. It is
    written out rather than derived, because the subtraction that used to stand in
    for "core has a schema" would now have hidden the entries core-03 opened.
  * The payload validator reads every keyword core declares rather than `type`
    alone — `enum`, `const`, `pattern`, `minLength`, `minimum`, `format`, nested
    `properties` and core's D11 `oneOf` — and **raises** on a keyword it does not
    model. Before, it would have reported "no problem" for five constraints it
    never read. A new drift test walks every keyword core uses and fails once, by
    name, when a shape appears the validator does not model.
  * `value_is_type?` understands a JSON Schema **type array**, so core's
    `["string", "null"]` is a disjunction and not an unknown type name. Its `else`
    still raises, and a test exercises that branch so it cannot quietly become a
    permissive `rescue`. `integer` stays Integer-only and `number` is modelled:
    a Float is never an amount in this service.
  * Every emitted envelope is checked, not the first with a matching type.
    `billing.payment.succeeded` has two shapes under D11 and the uuid tiebreaker
    was choosing which one to verify, on every run.
  * The corpus and the behaviour-not-text comparison survive, retargeted at the
    two constraints where core and this service each hold a pattern of their own:
    `Plan::SLUG_PATTERN` against core's `slug` pattern, and
    `Money::CURRENCY_FORMAT` against core's `^[A-Z]{3}$`.

  **No behaviour in `app/` changed.** The only change outside the test and the
  manifest is one stale comment in `Subscriptions::Lifecycle#payload`, which
  described core's pre-core-03 payload schema.

- **The HTTP document and the router are now held to each other by method *and*
  path, in both directions.** `test/contract/http_surface_contract_test.rb`
  replaces a path-only comparison that could not see a verb. It reads the
  document, the manifest and the route set — nothing from `core` — so it runs on a
  checkout that has no `core` beside it, which the spec it replaced did not
  (that one sits behind a `setup` that skips).

  * Every `(method, path)` in `openapi/v1.yaml` is served, and every
    `(method, path)` the router serves is either in the document or named on an
    exclusion list with the reason it is not a client operation. A route that is
    neither fails, so the list cannot grow an endpoint nobody argued about; an
    exclusion for a route that has gone away fails the other way, so a stale one
    cannot quietly cover whatever is added at that path next.
  * The exclusions are keyed by method **and** path and replace a
    `start_with?("/v1")` filter, which excluded the probes, the `exceptions_app`
    targets and every Rails engine route *incidentally* and could not see a verb
    on a `/v1` path.
  * Every operation is required to have an `operationId` and no `operationId`
    may be used twice, and the fifteen are pinned — a generator turns these into
    method names, so a duplicate or a rename is a compile error in a customer's
    language.
  * A route drawn `via: :all` has no verb constraint at all, so it is excluded
    under each of the seven methods rather than under a verb that is not a
    method, and a test reads that back out of the router.

  The `info.version` pin and the `exposes.api` manifest check moved to the same
  file, because they read the document rather than core. Both are unchanged: the
  version is still a pin and not a value derived from the document. The document
  is now read with `safe_load_file`, as the manifest beside it already was.

- **`info.description` now describes the document that exists.** It said the
  document "describes the v0 surface" while `info.version` read 1.1.0, and it
  promised prepaid credit, usage metering and invoices, which are not built. It
  describes the operations that are here and names what is deliberately not —
  the probes, the `exceptions_app` targets, the Rails engine routes, the
  features still to come — so *absent* and *forgotten* read differently. The
  header gains note 5, which states the rule above.

  `info.version` moves 1.1.0 → **1.2.0** for this: no operation moved, so the
  `/v1` prefix is untouched, and core's checklist asks for the bump if anything
  else in the document did — prose included.

### Fixed

- **`PUT /v1/customers/{id}` was served and was in no document.** The check that
  compared the document with the router read **paths only** and filtered the
  router with `start_with?("/v1")`, so `resources`' two verbs for one `update`
  were one path on each side and it reported agreement.

  The route is removed rather than documented. `V1::CustomersController#update`
  is a partial update — `CustomerUpdate` has every field optional and is closed,
  and `owner`/`processor` are not updatable because they are the key the
  uniqueness rule is built on — so a `PUT` describing it would be a document
  claiming a whole-resource replacement this service does not implement.
  `config/routes.rb` now spells the customer routes out, as it already did for
  plans and subscriptions. This is a narrowing of the served surface and nothing
  in `openapi/v1.yaml` declared it, so no operation changed and the `/v1` prefix
  is untouched.

### Known issues

- **The three `billing.subscription.*` payloads are published in a shape core's
  payload schemas reject.** core's D10 rewrote those schemas because "billing has
  no subscriptions table and cannot invent ids it does not have" — true of
  billing-03b, and not true of billing-04, which added the table and moved the
  subscription events onto billing's own ids (`subscription_id` is
  `Subscription#id`, which is also the envelope's subject, alongside `plan_id`,
  `account_id`, `currency`, `started_at` and `processor_subscription_id`). core's
  schemas are the processor-normalised shape billing-03b emitted and are closed
  with `additionalProperties: false`.

  Recorded in `PENDING_PAYLOAD_ALIGNMENT` and asserted in both directions, and
  raised as a DECISION NEEDED in `cafaye.yml`. core's own D10 names this as the
  second breaking change and core is read-only from a service worktree, so it is
  core's to make. Matching core from here would mean either emitting a payload no
  consumer has agreed to or dropping `plan_id` and `account_id`, which are the
  two fields that make a subscription event actionable.
- **core's `billing.plan.*` schemas do not name `entitlements`,** which
  billing-04 added to `Plan#as_json`. Same reasoning: a missing constraint in a
  core schema, recorded rather than worked around, because removing the field
  from the payload is a contract change and `Plan#as_json` is also the HTTP
  response shape.
- **`core: ^0.2.0` is pinned to the last released spec.** core's D10 is marked
  Breaking and is still in core's `[Unreleased]`, so there is no `0.3.0` to pin
  to. `^0.2.0` excludes it, so the day core tags it every service in the fleet
  has to move at once — a service whose CI resolves core would otherwise resolve
  a different core than the one this contract test reads off disk.

Billing domain v0, in three packets. **billing-02**: customers and plans — the
schema, the models, the `/v1` API, and the transactional outbox. **billing-03b**:
the Stripe webhook — a signed inbound event, stored once, turned into one of
this service's own events. **billing-04**: the subscription lifecycle — a
customer subscribes, moves between plans, and is cancelled, with the whole
state machine driven by the webhook and no status decided by a request.

billing-04 changes one claim the earlier packets made. "This service receives
from Stripe and does not talk to it" was true and is no longer: a subscription
is bought through a Stripe Checkout Session, cancelled by asking Stripe to
cancel, and moved between plans by asking Stripe to move it. The claim that
replaces it is narrower and checkable — **every request this service makes to
Stripe is one of the three methods on `Processor::StripeClient`, and there is no
other `Stripe::` call in the repository.** No new dependency: the `stripe` gem
was already here, for `Stripe::Webhook.construct_event`.

### Added

- **`subscriptions`** — id uuid, `account_id` (identity's uuid, no foreign key and
  no association, for the same reason `customers.owner_id` has none),
  `customer_id` and `plan_id` (real foreign keys), `processor_subscription_id`
  (**UNIQUE**, and that index is the resolution mechanism rather than a query aid —
  every event about a subscription is looked up by it), `status`, the current
  period, `cancel_at_period_end`, `canceled_at`, and `last_processor_event_at` —
  the processor's own `created` for the last event applied, which is the only way a
  delivery that arrived late can be told from one that arrived now. `timestamptz`
  for the instants.
  `UNIQUE [account_id, plan_id] WHERE status <> 'canceled'`: one *live*
  subscription per account and plan, because `canceled` is the only terminal
  status, and a customer who cancels and returns has to be able to subscribe to
  the same plan again.
- **`Subscriptions::StateMachine`** — the lifecycle as one pure object. The whole
  legal/illegal grid is a single table, so the set of *impossible* transitions is
  readable rather than inferred from conditionals. There is one rule and the rest
  of the lifecycle is ordinary code: **`canceled` is terminal, and nothing leaves
  it.** A status the processor uses and this service does not model
  (`incomplete`, `incomplete_expired`, `paused`) is refused by the constructor
  rather than coerced — a row that said `active` for a subscription the processor
  calls `incomplete` would grant entitlements nobody paid for.
- **`Subscriptions::Lifecycle`** — the **only** writer of a subscription's state and
  the only thing that emits its events. No `after_update` on `Subscription`, and no
  branch of the API that changes a status: cancelling and changing a plan both ask
  the processor and wait for the webhook. One writer means one answer to "what is
  this subscription's status", and it comes from the party that can bill.
  The event type is derived from *what the delivery did to the row* rather than
  from the processor's event type, which is what makes out-of-order delivery safe.
- **`Subscriptions::PlanChange`** — when a move to a different plan takes effect.
  **A more expensive plan takes effect immediately and the processor bills the
  difference; a cheaper or equally priced one takes effect at the end of the
  current period, with nothing carried forward.** The only arithmetic in the object
  is a comparison of two `Money` values; there is no credit, no refund, no prorated
  figure and no annualisation, so there is nothing in it that could disagree with
  the processor's books. Cross-currency and cross-interval comparisons are refused
  rather than guessed: ten dollars a month against a hundred a year is not a cheaper
  plan, it is a different unit.
- **`Processor::StripeClient`** — the whole outbound surface to Stripe: a Checkout
  session, a plan change and a cancellation. It sends a `proration_behavior` and
  never an amount; it asks for no refund and no proration on a cancellation,
  because the credit for an unused period is the processor's to compute and a refund
  calculated here would be a figure this service did not keep. The `api` keyword is
  the seam the specs replace, so a spec exercises this class's own argument
  building rather than a parallel implementation of it. A missing `STRIPE_API_KEY`
  is a `503` and never a `4xx`: it is this service's misconfiguration, and telling
  a caller its request was wrong when the service cannot reach Stripe at all sends
  an operator looking in the wrong place.
- **`plans.entitlements`** — jsonb, `{}` by default: what buying a plan grants.
  An object with at most `features` and `limits`, so a reader never has to ask
  whether a key it does not know is one it should honour. A limit is a *count*,
  never an amount: there is no currency in that object, deliberately. The shape is
  closed in `Plan` and the top level is held by three `CHECK` constraints, because
  a public field that consumers gate features on should not be a shape every reader
  guesses at.
- **`GET /v1/subscriptions/:id/entitlements`** — what the plan grants, and whether
  this subscription is granting it. A `canceled` subscription grants nothing
  (`features: []`, `limits: {}`); a `past_due` or `unpaid` one still grants,
  because the processor's grace period is a product decision and not this service's
  to take away.
- **`POST /v1/subscriptions`** — creates a Stripe Checkout Session and returns its
  URL. **It writes no subscription**, deliberately: a subscription does not exist
  until the payment completes, and a row for one that does not would be a sixth
  status meaning "we asked", which is a state no processor can report. The 201
  carries the session and no `Location`, because there is no resource to point at;
  the row appears when `customer.subscription.created` arrives.
- **`POST /v1/subscriptions/:id/cancel`** and
  **`POST /v1/subscriptions/:id/change_plan`** — ask the processor to act and
  return. Neither moves the local row, because a response claiming a cancellation
  had happened would be a lie about a state this service does not own.
  `at_period_end` is a required boolean: the caller chooses, and this service does
  not inherit a processor's default on its behalf. A `past_due` subscription cannot
  be cancelled at the end of a period it is not going to be charged for, and is a
  422 rather than a silent immediate cancellation. `change_plan` is the one place
  that returns something other than the row — a `plan_change` object saying whether
  the move takes effect immediately or at the period end — because without it a
  client cannot tell a caller that a downgrade is scheduled rather than applied.
- **A real coverage gate for the money paths.** `Coverage.start` runs *before* the
  application boots and the app is eager-loaded inside the measurement window,
  because measuring from inside the suite would report a file as covered when the
  corpus had merely autoloaded it. The gate's own honesty is asserted: a corpus
  that reaches almost nothing must be reported uncovered, and a method nothing calls
  must fail it. A second test partitions every file that touches money into money
  paths and files with money in them, so a new one cannot be added ungated — and
  the mixed files' money entry points are asserted behaviourally, so "not in the
  gate's list" never quietly means "not covered".

### Changed

- **`billing.subscription.started` now satisfies core's payload schema.** The gap
  `PENDING_PAYLOAD_ALIGNMENT` tracked since billing-03b is closed: a started event
  is now built to core's eight fields and nothing else, because that schema is
  closed with `additionalProperties: false`. What replaces it is smaller and is
  tracked in its own set: core asks for `sub_`/`pln_`/`acc_` prefixed ULIDs and
  this service's ids are uuids. Changing them is a breaking change to a contract
  several services already read, so it is a platform decision — and the contract
  test now asserts the disagreement in both directions, so a payload that starts
  matching fails rather than sitting there.
- **A subscription event's `subject` is billing's own `Subscription#id`**, not the
  processor's. This is the flip billing-03's `DECISION NEEDED` recommended landing
  with the table, and it is what lets a consumer join `started`, `updated` and
  `canceled` on one key with no lookup table. Payment events keep the processor's
  id, because an invoice references a subscription rather than being one.
- **Two assertions in the webhook integration spec changed, on purpose.** billing-03b
  asserted that a `customer.subscription.deleted` arriving before its
  `created` still emitted an event for each. That left an **active** subscription
  row — and an active row grants entitlements — for something the processor said
  was gone. billing-04 keeps the deletion as a canceled row, which grants nothing,
  and refuses the creation that follows. The endpoint's answer is unchanged: both
  deliveries are `200`.
- `Webhooks::Ingestion` passes the processor's event time to the handler as well as
  to the outbox row, so an event's `time` and its payload's `started_at` are one
  instant read once. The ingestion layer itself is otherwise unchanged; the ordering
  it already had is what puts the domain write and the event in one commit.
- `openapi/v1.yaml` is at `1.1.0` and `Plan#as_json` carries `entitlements`. Both
  are non-breaking additions under the same `/v1` prefix, which is core's rule.
- `cafaye.yml`'s `DECISION NEEDED` notes are updated rather than accumulated: the
  `subject` decision is closed, and a new one records that this service now talks
  to Stripe, with the narrower claim that replaces the old one.

### Not done

- **`billing.subscription.past_due` is not published.** It is in core's catalog and
  a failed charge is the obvious trigger for it, but this build reports arrears as a
  change to the subscription's status in `billing.subscription.updated` and states
  the failed charge in `billing.payment.failed`. Whether that is one event or two is
  a question about what a consumer does with them; a manager who wants the second
  type needs a row agreed in core first, and the mapping is then one line.
- **A subscription created directly in Stripe's dashboard is recorded as
  `ignored:unknown_customer`, not tracked.** It carries no cafaye customer id, and
  matching it to whoever shares an id would be a guess about whose money it is.
- **No trials, no usage-based and no seat-based billing.** Only the flat plan
  lifecycle the packet asked for. A `quantity` is reported in the event payload
  where the processor sends one, and is not a column, because nothing here can act
  on it.
- **The publisher loop still does not exist.** `published_at` is always null and
  nothing consumes these events, including courier.

### Added (billing-02 and billing-03b)

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
- **Eight events, three-segment and service-prefixed as core v0.2 requires**.
  Three from the models — `billing.customer.created`, `billing.plan.created`,
  `billing.plan.updated`, which fires only when a field actually changed — and
  five from the Stripe webhook mapping: `billing.subscription.started`,
  `billing.subscription.updated`, `billing.subscription.canceled`,
  `billing.payment.succeeded`, `billing.payment.failed`. `cafaye.yml` and
  `OutboxEvent::TYPES` hold the same eight, and `test/contract/` fails if either
  drifts, so a type cannot be emitted without a manifest row or advertised
  without an emitter.
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
  plus the published event types. This closes the `> DECISION NEEDED` that
  billing-01 recorded about the absent `exposes`.
- **`test/contract/`** — checks the emitted envelopes against core's real
  `event-envelope.schema.json` (reading core, not paraphrasing it), checks that
  the event-type and subject patterns this service validates with accept
  exactly the strings core's accept, and checks that the manifest and the code
  agree about which events exist and that the OpenAPI document is where the
  manifest says it is.

The following are packet **billing-03b**, the Stripe webhook. It receives; it
never calls.

- **The `stripe` gem (`~> 19.6`)** — the first dependency beyond Rails'
  defaults and `pg`, and the only one. This build uses exactly one thing from
  it: `Stripe::Webhook.construct_event`, the signature verification. The
  signature scheme (HMAC-SHA256 over `timestamp.body`, with a tolerance window)
  is the processor's contract, so re-implementing it would have been a
  hand-rolled crypto path in the one place a forged amount must never be
  believed. No API client, no OAuth, no outbound request. `Gemfile.lock` was
  changed in its own commit for this.
- **`POST /v1/webhooks/stripe`** — the one authenticated path in this service,
  authenticated by signature rather than by token. Verified with
  `Stripe::Webhook.construct_event` over `request.raw_post` and nothing else; a
  body that does not verify is a `400` and is **stored nowhere**. A verified body
  that is not an event is also a `400`, and a missing signing secret is a `503`
  rather than a `400`, because that is this service's misconfiguration and
  reporting it as a bad signature sends an operator looking in the wrong place —
  the cause is logged, the body says only `unavailable`. Every other outcome is
  a `200`. Declared in `openapi/v1.yaml` under its own `webhooks` tag, and a
  test asserts the manifest's `exposes.api` document declares the path that
  `config/routes.rb` serves.
- **`processor_webhooks`** — the at-most-once record of what a processor sent.
  `processor`, `stripe_event_id` (**UNIQUE**), `type`, `payload` jsonb stored
  verbatim, `processed_at` `timestamptz` (NULL meaning "received, not finished",
  the only state a crash leaves), `error` text, timestamps. Plus a partial index
  on the unfinished rows — the question this table gets asked first — and a
  `CHECK` on the processor, written out in the migration rather than read from
  the model so the migration keeps meaning what it meant the day it ran.
  `ProcessorWebhook.ingest` turns the unique conflict back into a lookup, so two
  concurrent deliveries of one event produce one row.
- **`Webhooks::Ingestion`** — the boundary: store what arrived, act on it exactly
  once, record how it went. The outbox row and the `processed_at` that says the
  delivery is finished are **one commit**, so there is no window in which a
  consumer can see the event while the row still looks unfinished — and no
  process that dies between them can leave a published event that a redelivery
  would duplicate.
- **`Webhooks::StripeEvents`** — the processor's shape stops here. One registry
  builds both the handler table and the event-type table, so a type cannot be
  normalizable but un-emittable, or vice versa. Nothing is defaulted: a field
  the processor did not send is absent from the normalized hash rather than
  invented, because a webhook payload is the weakest input in the system and a
  silent default is how a customer ends up on a plan nobody charged them for.
  Amounts cross as `Money#to_h` — `{"amount_minor", "currency"}`, the platform's
  single wire shape for money — so a non-integer raises here rather than being
  rounded.
- **Nine committed Stripe fixtures** under `test/fixtures/stripe`. The webhook
  specs post the committed bytes, signed with a constant that is a credential for
  nothing, and assert against the real verification path: no network, no stubbed
  verifier. The fixtures' `created` timestamps are what the event-time
  assertions derive from, so a fixture edited without its tests failing is a
  fixture nobody looked at.
- **`config/database.yml` names its databases per checkout.** Worktrees run side
  by side, and two sharing one database name is not a near-miss: one worktree's
  `db:migrate` silently applies the other's migrations, `db/schema.rb` ends up
  holding tables neither branch has committed, and the suite passes against a
  schema the code does not describe. The name is derived from the directory, so a
  plain `billing/` checkout still gets `billing_development`;
  `BILLING_DATABASE_NAME` overrides it. CI sets `DATABASE_URL` and never reads
  it. Not part of the webhook, and not part of the outbox reconciliation — it is
  what made this worktree's gate runnable while two sibling worktrees shared a
  PostgreSQL on :5432.
- **`openapi/v1.yaml` is the union, not a replacement.** billing-02's customers
  and plans paths, schemas and responses are untouched; the webhook arrives as a
  new `webhooks` tag, one path, one header parameter, two schemas and two
  responses. Every problem body it declares is the same
  `application/problem+json` from `app/lib/problem.rb` the rest of the service
  returns — the parallel branch carried its own renderer and it is **not** in the
  tree, because a second error shape on one service is distinguishable only by
  which controller answered.

### Changed

- **The outbox row and the `processed_at` that marks a delivery finished are now
  one transaction** (packet billing-03b). The parallel branch wrote them as two,
  which is a window in which a process that dies leaves a row looking unfinished
  with the event already published — and the next delivery then emits a *second*
  `billing.payment.succeeded` with a second envelope id for one charge, the exact
  duplicate the table exists to prevent. A `before_update` that raises is the
  reachable stand-in for that process death, and three specs hold the property:
  a marking that cannot be written leaves no event behind it, leaves the row
  visibly unfinished, and the next delivery completes it exactly once.
- **`db/schema.rb` is one coherent schema**: `customers`, `plans`,
  `idempotency_keys`, `outbox_events`, `processor_webhooks` and `subscriptions`,
  at version `20260930000009`. Both branches created their own `outbox_events`
  migration; billing-02's is the one that stands, and each later packet adds a
  table or a constraint rather than a second definition of anything.

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
- `OutboxEvent.publish!` takes a `time:` keyword (packet billing-03b). The
  default is unchanged, so the model-callback path is exactly as it was, but a
  webhook's event now carries the **processor's** timestamp rather than the
  moment this service wrote the row. A row that sat unpublished for an hour must
  still report when the change happened, and it is the only way an out-of-order
  delivery is detectable: two events stamped on arrival appear to have happened
  in the order they arrived.
- `OutboxEvent::TYPES` and `cafaye.yml`'s `exposes.events` went from three types
  to eight (packet billing-03b). The list is now closed in the enforcement
  direction too — a type that is not on it cannot be written at all, which is
  what stops a mapping from parking every delivery as a failure.

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
- **`processor_webhooks.type` is the processor's type, not an STI column**
  (packet billing-03b), so the model sets `self.inheritance_column = nil`. That
  line is load-bearing rather than tidiness: without it every `find` on the table
  tries to resolve `customer.subscription.updated` to a class and raises — which
  is how a table storing a third party's type strings breaks an ordinary query.
- **The unique index on `stripe_event_id` is the correctness mechanism, not a
  query aid** (packet billing-03b). It is declared explicitly in the migration
  rather than as `index: true` on the column, and `ingest` catches the conflict
  and returns the row the winner stored. A `500` there would tell Stripe to
  redeliver, which is the one thing guaranteed to race again.
- **Every terminal webhook outcome is a `200`** (packet billing-03b): a replay,
  an unmapped type, a deliberate ignore, and a mapping that raised are all
  recorded and all answered 200. A `5xx` would teach Stripe to retry a decision
  this service has already made, and would hide a parked row behind a timeout.
  `processor_webhooks.error` is the record: `ignored:<reason>` for a decision,
  `failed:<class>: <message>` for a row parked for a human, NULL `processed_at`
  for the one state a crash leaves.
- **A failed invoice reports `amount_due`, not `amount_paid`** (packet
  billing-03b). The obvious `amount_paid || amount_due` is wrong: the failed
  fixture carries `amount_paid: 0`, and `0` is truthy in Ruby, so it would report
  a failed 29.00 charge as a settled 0.00. Money is not worth a clever fallback.
- **Nothing on the webhook is token-authenticated, and nothing there may become
  so** (packet billing-03b). The sender is a processor, not a cafaye client. A
  `Bearer` on that path would be a second, weaker trust path to the same door.

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
- No subscriptions, no Stripe API calls, no invoices, no metered usage, no
  prepaid credit, no `pay_*` tables. Those are later packets and each needs its
  own brief — with the user reviewing the diff, since this is the service that
  holds the money. The webhook is the **report** of a state change, not the
  state: nothing in this packet writes a subscription or a payment, and
  `subject` is therefore the processor's own id (recorded as a `> DECISION
  NEEDED` in `cafaye.yml`; flipping it is one line in
  `Webhooks::StripeEvents.subject_for`).
- **The webhook receives and never calls.** `processor`,
  `processor_product_id` and `processor_price_id` are still stored and returned
  and still null in practice. There is no client, no OAuth, and no outbound
  request to Stripe anywhere in this repository.
- `checkout.session.completed` in payment mode becomes
  `billing.payment.succeeded`, because no invoice event exists for a one-time
  Checkout and that charge must not be lost. A **subscription-mode** session is
  deliberately ignored, with the reason recorded: it restates
  `customer.subscription.created` a moment later as a separate delivery with a
  separate envelope id, and emitting both would state one fact twice, so a
  consumer counting `billing.subscription.started` would count every Checkout
  signup twice.
- `billing.plan.updated` has no catalog row in core, and core has no payload
  schema for any event except one. Both gaps are recorded in `cafaye.yml` and
  enforced against this repository by `test/contract/` — asserted **as sets**,
  not subtracted from the failures, so a payload that starts matching still has
  to be deleted from the list deliberately. `billing.subscription.started` is
  published even though it does not satisfy core's payload schema: the catalog
  row exists, the envelope is core-shaped, and a payload a consumer cannot yet
  read is a gap in core rather than a reason to stop publishing. Concretely, core
  requires `plan_id` and `account_id` as `pln_…` and `acc_…` values and is
  closed over eight fields; this build has no subscriptions table, `Plan#id` is a
  uuid, and the normalized payload carries eleven keys core does not name. The
  difference is recorded as a `> DECISION NEEDED` in `cafaye.yml`; closing it is
  a core-side decision plus a subscriptions table.
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

No metered usage, no prepaid credit, no `pay_*` tables, and no publisher loop.
Those are later packets and each needs its own brief — with the user reviewing the
diff, since this is the service that holds the money.
