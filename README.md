# billing

`billing` is the cafaye service that owns money: plans, customers, subscriptions,
prepaid credit, usage metering, and webhooks coming in from a payment processor.
Every other cafaye service that charges someone — `parlor` at checkout, `muse`
when it meters a completion — accounts through this one.

**v0 is customers, plans and the Stripe webhook.** The schema, the models, the
`/v1` API and the transactional outbox exist and are tested, and a processor's
signed event can be received, stored once, and turned into one of this service's
own events. There is still no outbound Stripe call anywhere in this repository:
`processor`, `processor_product_id` and `processor_price_id` are stored and
returned, and all three are null in practice. This service receives from Stripe;
it does not talk to it.

```sh
$ curl -s localhost:3000/healthz
{"status":"ok"}

$ curl -s localhost:3000/readyz
{"status":"ok","checks":{"database":"ok"}}

$ curl -s localhost:3000/v1/plans/pro-monthly
{"id":"…","name":"Pro monthly","slug":"pro-monthly","processor_product_id":null,
 "processor_price_id":null,"price":{"amount_minor":1900,"currency":"USD"},
 "interval":"month","trial_days":0,"active":true,"created_at":"…","updated_at":"…"}
```

and, when PostgreSQL is unreachable, `/readyz` answers
`503 {"status":"error","checks":{"database":"error"}}`.

## Money

`app/models/money.rb` is the seed of the platform-wide rule that money is
**integer minor units** and never a Float (`PLAN.md` §3). It is a frozen value
object: an integer amount, an ISO 4217 currency, and arithmetic that refuses
rather than guesses.

```ruby
Money.new(1050, "USD")                      #=> #<Money 10.50 USD>
Money.from_major("10.50", "usd")            #=> #<Money 10.50 USD>
Money.new(1050, "USD") + Money.new(50, "USD") #=> #<Money 11.00 USD>
Money.new(1050, "USD") * 3                  #=> #<Money 31.50 USD>
Money.new(1050, "USD").to_h                  #=> {"amount_minor"=>1050, "currency"=>"USD"}
```

What it will not do, and why each refusal is deliberate:

```ruby
Money.new(10.5, "USD")            #=> raises Money::InvalidAmountError
Money.from_major("10.505", "USD") #=> raises: would have to round
Money.from_major("10.5", "JPY")   #=> raises: JPY has no minor unit
Money.new(1, "USD") + Money.new(1, "EUR") #=> raises Money::CurrencyMismatchError
Money.new(2**63, "USD")           #=> raises Money::OverflowError
Money.new(100, "USD") - Money.new(250, "USD") #=> raises: a negative by subtraction
```

A Float cannot represent `0.10`, so it never carries an amount. Rounding is
never silent, because a rounded price is a bug that surfaces in somebody's
invoice. Mixing currencies is an error, because FX is a pricing decision rather
than an arithmetic one. Currencies whose minor unit is not `10^-2` — JPY and
KRW at zero decimals, KWD and the Gulf dinars at three — carry their real ISO
4217 exponent, which is the case a two-decimal assumption corrupts quietly.

The class comment has the reasoning in full; `AGENTS.md` has the rules.

### The wire

A price crosses the API as minor units and an integer, and nothing else:

```json
{ "price": { "amount_minor": 1900, "currency": "USD" } }
```

`{"amount_minor": 19.00}` and `{"amount_minor": "19.00"}` are both `422`. The
first has already lost the fact that it was nineteen dollars exactly; the second
would mean this API has two representations for an amount. `Plan#price` returns
a `Money` and `Plan#price=` accepts only a `Money`, so no code path writes
`amount_cents` without also writing the currency beside it.

The event payloads use the same representation, so an event and a response can
never disagree about what something costs.

## API

`openapi/v1.yaml` is the contract. It is written against core's
`docs/openapi-conventions.md`, which is where the rules below come from.

| | |
| --- | --- |
| `POST /v1/customers` · `GET /v1/customers` | create and page through customers |
| `GET /v1/customers/:id` · `PATCH /v1/customers/:id` | read and update by uuid |
| `POST /v1/plans` · `GET /v1/plans` | create and page through plans |
| `GET /v1/plans/:slug` | read by the public handle |
| `PATCH /v1/plans/:id` | write by uuid |

The plans asymmetry is deliberate: a slug can be changed by the very request
being made, and a mutable handle is not a safe thing to address a mutation by.
Each endpoint answers 404 for the other's identifier.

**Authorization is a later platform packet, and the `/v1` surface is open until
it is not.** No endpoint reads a token, because there is no token to read: core
says identity is the only issuer and that services verify against the JWKS, and
that machinery is not in this repository yet. The visible consequence is
`GET /v1/customers`, which returns every customer, because without a token there
is no `account_id` to scope a query by. Do not expose this surface to anything
but the gateway.

Errors are `application/problem+json` — RFC 9457 with core's extensions, built
in one place (`app/lib/problem.rb`) so no controller can invent its own:

```json
{
  "type": "https://errors.cafaye.com/validation_failed",
  "title": "Validation failed",
  "status": 422,
  "detail": "slug can't be blank; price must be an object with an integer amount_minor and a three-letter currency",
  "instance": "/v1/plans",
  "code": "validation_failed",
  "trace_id": "0af7651916cd43dd8448eb211c80319c",
  "errors": [ { "field": "price", "code": "invalid_format" } ]
}
```

`X-Trace-Id` is on every response and repeated in the body of every error.
Collections are cursor-paged (`data` + `page`, default 25, capped at 100, cursors
expire after 24 hours). `POST` accepts `Idempotency-Key`; a replay with the same
body returns the original response with `Idempotency-Replayed: true`, and a
replay with a different body is a `409`. A duplicate customer or slug is a `409`
rather than a `422`: the request was well-formed, it just collides.

## Events

Eight events, all three-segment and prefixed with this service's own name, as
core v0.2 requires. Three come from the models, five from the Stripe webhook:

| Type | Subject | When |
| --- | --- | --- |
| `billing.customer.created` | the customer | a customer is created |
| `billing.plan.created` | the plan | a plan becomes billable |
| `billing.plan.updated` | the plan | a plan changes |
| `billing.subscription.started` | the subscription | Stripe says a subscription became active |
| `billing.subscription.updated` | the subscription | plan, quantity or interval changed |
| `billing.subscription.canceled` | the subscription | a cancellation took effect |
| `billing.payment.succeeded` | the payment | a charge settled |
| `billing.payment.failed` | the payment | a charge was declined or errored |

They are written to `outbox_events` **in the same transaction** as the change
they describe — from `after_create`/`after_update` for the three model events,
and for the five webhook events in the same transaction that marks the delivery
finished. Never `after_commit`, and never a background job: a separate
transaction is a window in which the database says the thing happened and the
event does not. A rollback takes the event with it. The column list is core's
contract (`core: docs/event-outbox.md`); `id` is the envelope's `id`, generated
before the insert so a republish is the same id.

`billing.plan.updated` is emitted only when a field actually changed. A `PATCH`
that sets a field to the value it already holds is not a state change, and an
event that says otherwise teaches a consumer to expect updates that carry no
update.

There is deliberately no `billing.customer.updated`: core's catalog has no row
for it, and a service that publishes a type the catalog does not list is a
service whose manifest is lying. The API can still change a customer's email
and nothing downstream is told. That gap belongs to whoever owns the catalog.

## Webhooks in

`POST /v1/webhooks/stripe` receives Stripe's events. It makes no Stripe API call
— this service only ever receives.

**The signature is checked against the raw bytes.** `Stripe::Webhook.construct_event`
over `request.raw_post`, never over a re-serialized parse. A body that does not
verify is refused with a 400 and **stored nowhere**: an unverified payload is not
an event, and writing one would put an attacker's JSON in the row a human reads
when something is wrong.

**A replay is a non-event.** Delivery is at-least-once, so the same event id will
arrive again — immediately, or a day later. `processor_webhooks.stripe_event_id`
is `UNIQUE`, and that index is the correctness mechanism rather than a query aid:
two concurrent deliveries of one event produce one row, one `processed_at`, and
one `billing.payment.succeeded`. The outbox row and the marking are a single
commit, so a process that died between them cannot leave an event published with
a row that still looks unfinished.

**The processor's own timestamp is the event's `time`**, not the moment this
service received it. That is what makes an out-of-order delivery detectable: two
events stamped on arrival would appear to have happened in the order they
arrived.

```json
{ "id": "evt_1PZQaBcDeFgHiJkLmNoPqR4", "type": "invoice.paid", "data": { "object": { "amount_paid": 8700, "currency": "usd" } } }
```

```json
{ "type": "billing.payment.succeeded", "subject": "sub_1PZQaBcDeFgHiJkLmNoPqR1",
  "data": { "kind": "payment", "amount": { "amount_minor": 8700, "currency": "USD" },
            "processor": "stripe", "processor_event_id": "evt_1PZQaBcDeFgHiJkLmNoPqR4" } }
```

The processor's shape stops at the normalizer. Everything downstream is
snake_case with integer minor units, and nothing that has not been sent is
defaulted — a webhook payload is the weakest input in the system, and a default
that silently fills a gap is how a customer ends up on a plan nobody charged
them for.

**Every terminal outcome is a 200.** A replay, an event type this build has no
mapping for, a type it deliberately ignores (`ping`; a subscription-mode
Checkout session, which restates `customer.subscription.created`), and an event
whose mapping raised are all recorded and all answered 200. A 5xx would teach
Stripe to retry a decision this service has already made and would hide a parked
row behind a timeout. `processor_webhooks.error` is the record:

| `error` | Meaning |
| --- | --- |
| `NULL` | the event became an event |
| `ignored:<reason>` | understood, deliberately not acted on |
| `failed:<class>: <message>` | parked for a human |

A 503 rather than a 400 is the answer when no signing secret is configured: that
is this service's misconfiguration, and telling Stripe its signature was bad
would send an operator looking in the wrong place. The cause is logged; the body
says only `unavailable`.

Nothing here is token-authenticated, and nothing here may become so — the sender
is a processor, not a cafaye client. A `Bearer` on this path would be a second,
weaker trust path to the same door.

## Known gaps

Written down rather than hidden. Each one is a decision this packet did not get
to make, not an oversight.

- **No authorization.** See above. The `/v1` surface is open.
- **No publisher loop.** The outbox table and the transactional insert are here;
  the process that moves rows to NATS is not. `published_at` is therefore always
  null and `attempts` always zero, and `outbox_events` grows without bound. This
  is the one gap that is a real operational risk rather than a missing
  convenience: until a publisher exists, nothing consumes these events.
- **No retention.** `IdempotencyKey#expired` and `OutboxEvent#unpublished` exist
  to be pruned on a schedule; nothing schedules them. core is explicit that an
  unpruned outbox is the largest table in the database.
- **`billing.plan.updated` has no catalog row in core.** See `cafaye.yml`.
- **No payload schemas in core for these three events.** core's outbox checklist
  asks for `data` to be validated against
  `schemas/events/<service>/<entity>/<action>.schema.json`; core ships two
  payload schemas in total and neither is billing's.
  `test/contract/` enforces the rule for every event that has one.
- **Cursors are not signed.** They are base64url and opaque, which is all core
  requires, but nothing stops a client crafting one. It can only ask for a
  different page of a collection it can already read, and the endpoints are open
  anyway. Signing needs a secret this service does not have.
- **Three problem codes are not in core's reserved list**: `bad_request`,
  `cursor_invalid`, `cursor_expired`. See `cafaye.yml`.
- **The unique-index race is handled but untested.** A `RecordNotUnique` that
  slips past the validations is a `409`, which is right; proving it needs two
  concurrent writers, so no spec covers that line.
- **A webhook event's `subject` is the processor's own id.** There is no
  subscriptions table yet, so a subscription or payment event carries Stripe's
  subscription id when the payload has one and Stripe's customer id otherwise. A
  consumer cannot join these to a cafaye account without that mapping, and a
  subscriptions packet will change the subject — a semantic change to every
  event already published. Recorded as a DECISION in `cafaye.yml`; it is one line
  in `Webhooks::StripeEvents.subject_for`.
- **`billing.subscription.started` does not match core's payload schema**, and
  cannot until this service holds the ids that schema describes. Core's
  `schemas/events/billing/subscription/started.schema.json` requires `plan_id`
  and `account_id` as `pln_…` and `acc_…` values, and is closed over eight
  fields. There is no subscriptions table, and `Plan#id` is a uuid. The event is
  published anyway — the catalog row exists, the envelope is core-shaped, and a
  payload a consumer cannot yet read is a gap in core rather than a reason to
  stop publishing. The exact difference is asserted as a set in
  `test/contract/outbox_envelope_contract_test.rb`, so the day the payload
  changes this file has to change with it. Closing it is a core-side decision
  plus a subscriptions table.

## Health

Two probes, with different jobs, because conflating them causes restart storms:

- `GET /healthz` — liveness. Answers as long as the process serves requests. It
  touches no dependency on purpose: a liveness check that fails when the
  database is slow takes the whole fleet down to fix one slow box.
- `GET /readyz` — readiness. Runs `SELECT 1` on a leased connection and answers
  `503` with a JSON body when the database cannot answer, so the load balancer
  stops sending traffic. The underlying error is logged and never returned: the
  body is read by anything that can reach the port.

Both are integration-tested, including the database-down path, which is
exercised by faking the leased connection rather than by pulling a plug.

## Running it

Ruby 4.0.1 and PostgreSQL 17. Nothing else — the dependency floor is Rails'
defaults plus `pg`.

```sh
mise install            # or use any Ruby 4.0.1
docker compose up -d    # postgres on :5432
bin/prime               # bundle, db:prepare, rubocop, rails test
bin/rails server        # http://localhost:3000
```

`bin/prime` is the gate and is what CI runs. If you already have a PostgreSQL on
the machine, skip the compose file: `config/database.yml` connects over the
local socket as the current user.

Point the app at a database elsewhere with `DATABASE_URL`, the same variable CI
uses:

```sh
DATABASE_URL=postgres://billing@localhost:5432 bin/rails db:prepare
```

## Tests

```sh
bin/rails test                      # the whole suite
bin/rails test test/models/money_test.rb
```

Minitest, no test framework gem. Clocks are injected with ActiveSupport's
`travel_to` rather than read, so no assertion depends on the day it was written.
`money.rb` is held to 100% line and branch coverage, measured with the standard
library's `Coverage` so the gate costs nothing.

`test/contract/` is the half of the suite that reads `core`: it checks the
emitted envelopes against core's real `event-envelope.schema.json`, checks that
the patterns this service validates with accept exactly the strings core's do,
and checks that `cafaye.yml` and the code agree about which events exist. It
skips, loudly, when `core` is not on disk; set `CORE_PATH` to point it elsewhere.

## Layout

```
app/controllers/v1/                 customers and plans
app/controllers/webhooks/           inbound from a processor: raw body, signature
app/controllers/concerns/            trace id, problem+json, cursor paging, idempotency
app/controllers/errors_controller.rb what Rails raises into
app/models/customer.rb               owner_type + owner_id, one per processor
app/models/plan.rb                   price is a Money or it is not a price
app/models/processor_webhook.rb      what a processor sent, stored once
app/models/outbox_event.rb           the event, and the envelope it becomes
app/services/webhooks/               store once, normalize, emit — in that order
app/lib/problem.rb                   the one error shape
app/lib/money_params.rb              the only place a request becomes an amount
openapi/v1.yaml                      the HTTP contract
test/contract/                       the checks against core
cafaye.yml                           the manifest
```

## Running it

Two environment variables are needed for the webhook to answer at all:

| Variable | Meaning |
| --- | --- |
| `STRIPE_WEBHOOK_SECRET` | the endpoint's signing secret. Unset, every request is a 503 `unavailable` rather than a 400, because that is this service's misconfiguration and not the sender's. |
| `STRIPE_WEBHOOK_SECRETS` | a comma-separated list, for a rotation. A signature that verifies under any configured secret is accepted. |
| `STRIPE_WEBHOOK_TOLERANCE` | seconds, default 300. The window in which a captured request stays replayable. |

Nothing is stubbed in the specs: the suite signs committed fixture bytes with a
constant that is a credential for nothing and exercises the real verification
path, so there is no network in `bin/rails test`.

## Conventions

Read `AGENTS.md` before changing anything here. It is the contract: money is
integer minor units, time is UTC, IDs are opaque strings, lockfiles are never
edited as a side effect, and nothing is copied out of `moon/refs/`.

## License

Released under the same license as the rest of cafaye. See `LICENSE` once the
manager adds it — this repository is public and the file is not written yet.
