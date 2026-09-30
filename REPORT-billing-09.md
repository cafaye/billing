# REPORT — billing-09: the duplicate-payment race

**Branch:** `worker/billing-09-race`, branched from `worker/billing-08`.
**Not pushed.** The manager pushes after the gate is green.

Two commits, in the order the brief asked for:

| commit | what it is |
|---|---|
| `b394a62` | billing-08's uncommitted work, finished, plus the stale-delivery guard |
| the second commit | the race fix: the outbox constraint, the ingestion change, and their regression tests |

---

## 1. The race is real, and it was a duplicate charge

**One Stripe event id produced two `billing.payment.succeeded` outbox rows.**

The previous worker's probe found it and printed:

```
GATE READS: 2
OUTBOX EVENTS for one event id: 2
RACE REPRODUCED: true
```

I reproduced it independently, as a real assertion, and it is now a permanent test.
With the new index removed from the database:

```
Webhooks::ConcurrentDeliveryTest#test_two_simultaneous_deliveries_of_one_event_id_emit_one_event:
one Stripe event id produced 2 outbox rows. Two rows are two envelope ids, and core's
envelope id is the dedupe key — a consumer cannot tell the second from new information
about the same charge.
Expected: 1
  Actual: 2
```

Two rows are two `id` values, and core defines the envelope `id` as the dedupe key. A
consumer deduplicating on it **cannot tell the duplicate from new information about
somebody's money.** That is the cost, and it is why this was the highest-value thing in
the packet.

### The mechanism

`Webhooks::Ingestion#call` is a check followed by an act:

```ruby
webhook = ProcessorWebhook.ingest(...)   # unique index on stripe_event_id
return webhook if webhook.handled?      # the read
dispatch(webhook)                       # ... and the write
```

The unique index on `processor_webhooks.stripe_event_id` makes two concurrent
deliveries of one event id agree about **which row** they are working on. `AGENTS.md`
is right that this index is the correctness mechanism for storing a delivery once — and
it is not sufficient, because **agreeing about the row is not agreeing about the answer.**
`handled?` reads `processed_at`, a column neither thread has written yet, because each
is about to write it. Under READ COMMITTED neither sees the other's uncommitted work, so
both read `nil`, both dispatch, and one event produces two events.

The brief's framing — that the lifecycle reads the subscription before it writes — is the
same shape of defect, and it is the reason the stale-delivery guard **cannot** catch this:
both deliveries carry the *same* processor timestamp, so both are equally current, and
each is comparing against a row the other has not yet changed. Ordering and at-most-once
are different guarantees. Neither substitutes for the other, and I did not remove either.

---

## 2. The fix: a database constraint

I checked whether the index existed before assuming it did not, as the brief asked.
**It did not exist.** `outbox_events` had two indexes, neither of them unique and
neither on a processor event id:

```
["outbox_events_subject_created_at_idx", false]
["outbox_events_unpublished_idx", false]
```

So a duplicate was a *permitted state* of the table, and no amount of application-level
checking fixes a permitted state under concurrency.

### The constraint

`db/migrate/20260930000010_index_outbox_events_on_processor_event_id.rb` — a **partial
unique index over the payload's `processor_event_id`**:

```ruby
add_index :outbox_events, "((data ->> 'processor_event_id'))",
  unique: true,
  where: "data ->> 'processor_event_id' IS NOT NULL",
  name: "outbox_events_processor_event_id_idx"
```

**Why an index over `data` and not a column.** `AGENTS.md` says the outbox column list
is core's contract, not local — core's `docs/event-outbox.md` says "the column list is the
contract; the implementation is the service's business." Adding a `processor_event_id`
column would be changing that contract. The key is already in `data`, because
`Webhooks::StripeEvents.provenance` puts the processor's own id in every webhook-emitted
payload. So this is a functional index over an existing column: **no column added, no
envelope attribute added.**

**Why partial.** The three model-callback emissions (`billing.customer.created`,
`billing.plan.created`, `billing.plan.updated`) are not the product of a processor
delivery and have no such key. `WHERE … IS NOT NULL` leaves them alone and keeps the index
from carrying an entry per callback event forever. Tested both ways: a `null` and a value
coexist in the same table.

### Why a constraint and not an advisory lock or `FOR UPDATE`

The brief's preference order is right, and the deciding argument is one sentence: **a
constraint holds under any interleaving, and an application-level guard holds only under
the interleavings its author imagined.** `SELECT … FOR UPDATE` on the subscription row
would also have left `invoice.paid` — which writes no subscription row at all — completely
unprotected, and the payment is where the money is.

### What makes it a *good* refusal rather than a 500

`Ingestion#emit` now has a `rescue ActiveRecord::RecordNotUnique` branch that records
`ignored:duplicate_delivery`:

```ruby
rescue ActiveRecord::RecordNotUnique
  webhook.ignore!(DUPLICATE_REASON)
```

Without it the loser would be parked as `failed:ActiveRecord::RecordNotUnique…` — a row in
front of a human at 3am for an event that is published and perfectly correct. I verified
this branch is load-bearing by deleting it, and it is red on 4 tests:

```
the losing creation was parked as a failure: ["failed:ActiveRecord::RecordNotUnique:
PG::UniqueViolation: … outbox_events_processor_event_id_idx …", nil]
Expected: 1
  Actual: 0
```

The application-level guard from Part 1 is **kept**, as the brief instructed. It is what
produces a good `Refused` reason for a delivery that arrived *late*, which the constraint
never sees — the two have different keys and different triggers.

### And a second gap in that rescue, which the first draft of this report got wrong

`rescue ActiveRecord::RecordNotUnique` was **not enough**, and the reason is the one
place where the two duplicate routes differ.

`subscriptions` carries a uniqueness **validation** on `processor_subscription_id` in the
model *and* a unique **index** over the same column. Two racing threads can be refused by
either, and which one wins is a scheduling accident. Measured over **60** barrelled
duplicate `customer.subscription.created` deliveries, on the state this report describes:

| outcome | count |
|---|---|
| loser recorded `ignored:duplicate_delivery` | 57 |
| loser parked as `failed:ActiveRecord::RecordInvalid` | **3** |

All 60 were the same fact — one delivery, acted on once, never two subscriptions. So a
uniqueness *failure* is now classified as the duplicate the index already records:

```ruby
rescue ActiveRecord::RecordInvalid => e
  uniqueness_race?(e) ? webhook.ignore!(DUPLICATE_REASON) : park(webhook, e)
```

`uniqueness_race?` asks the record whether an error of Rails' `:taken` type is in it, not
whether the exception class looks right — which is what keeps the rescue narrow. A
`RecordInvalid` carrying any *other* validation failure is a bug in this service and still
parks; that is a separate test, not an absence.

Two things make this worth having rather than filing:

1. **It was a production defect**, not a test artefact: 5% of duplicate subscription
   creations parked a row in front of a human for an event that was published and correct.
2. **It was a 5% flake in the very regression test this packet exists to write.** The
   shipped `refute records.any?(&:failed?)` passed 10/10 in isolation and would still have
   failed in CI eventually. The brief's rule — no sleeps, no raised retries, no loosened
   assertions, and "it passed most of the time" is not a result — is why the distribution
   was measured instead of sampled.

After the change: **60 of 60** recorded `ignored:duplicate_delivery`, **0** parked, **0**
duplicate subscriptions. Re-measured, not assumed.

The other thing the index caught — three test helpers delivering under an event id their
own payload did not carry — is a separate finding and has its own section, **§7b**.

---

## 3. The concurrency test, and the no-sleeps rule

`test/services/webhooks/concurrent_delivery_test.rb`, 10 tests, 24 assertions.
**No sleep, no retry, no loosened assertion, anywhere.**

The interleaving is **manufactured, not hoped for**. `ProcessorWebhook#handled?` is the
mouth of the check-then-act window, and a two-party barrier (`Mutex` + `ConditionVariable`,
no timeout) holds both threads in it until both have arrived. Without that, "two threads,
same event id" is a *probable* duplicate — and a test asserting a probable outcome is a
flake generator, which is exactly what the brief and `AGENTS.md` both refuse.

Stability, measured: **8 consecutive runs, 10 runs / 24 assertions / 0 failures / 0 errors
/ 0 skips**, every one.

### Two things about the barrier that are not obvious

**It uses `alias_method`, not `prepend`.** Ruby cannot un-prepend a module, and a
file-scope `prepend` in a test changes every other test in the suite for the rest of the
run. The original restores in `ensure`. (The repository's `simple_stubs` cannot do this:
it aliases onto a *singleton*, and this is an instance method on the class.)

**The query cache is dropped before any count is read.** This one was found the hard way
and is worth recording. Active Record's query cache is **on** in the test environment, it
is cleared between tests but **not within one**, and every count in this file is taken on
the main thread *after* the worker threads have committed. Nothing a worker thread did
invalidates anything this thread read earlier. With the cache live, counts came back
stale — `Actual: 0` for a table that held a finished, committed row, and a run reporting
`4 outbox rows` where there were `2`. A count that cannot see the rows it is counting is a
tripwire wired to nothing, and this is the one file in the repository where a green count
would have meant nothing at all. The barrier's block now ends by clearing the cache once,
and every count reads through `ActiveRecord::Base.uncached`.

### Also: the negative controls

- **Two different event ids must still be two events.** An index written over the wrong
  expression — `subject`, say — would refuse a subscription's `started` then `updated` and
  break real deliveries while looking like it worked. Asserted in both directions.
- **A start payload carries no `processor_event_id`**, asserted, so it cannot silently
  become the thing the other half of the file tests.

---

## 4. The second duplicate route, which the new index does *not* close

This is the part I did not expect, and it is the most useful thing in the packet after the
fix itself.

`billing.subscription.started` is published for a `customer.subscription.created`, and
**that payload carries no `processor_event_id`** — the lifecycle's start payload is
`core_payload` plus `started_at`, and `lifecycle_test.rb` asserts the key's *absence*. So
the new outbox index cannot be what refuses a duplicate creation: the second `INSERT` into
`subscriptions` is refused first, and the outbox insert is never reached.

**Which constraint refuses it is not a fact, and the first draft of this report named one
and was wrong.** I measured each case by dropping one index at a time and re-running the
same two barrelled deliveries:

| `subscriptions` indexes | result |
|---|---|
| all present | `subs=1 started=1 outbox=3` — refused |
| without `index_subscriptions_on_processor_subscription_id` | `subs=1 started=1` — **still refused** |
| without `subscriptions_live_account_plan_idx` | `subs=2 started=2 outbox=4` — **duplicate reopened** |
| without **any** of them | `subs=2 started=2 outbox=4` — duplicate reopened |

The reason the second row still refuses is that the refusal is not only the index: the
model carries a uniqueness **validation** on `processor_subscription_id`, so with the index
gone the losing thread is refused by Rails instead. And the outcome is not even stable run
to run — over 60 barrelled deliveries the loser was refused by the index 57 times and by
the validation 3.

So the property rests on **a validation and an index, together**, and the statement that
holds is the negative one: drop every index on `subscriptions` and the duplicate reopens
with nothing left to catch it. No single constraint is sufficient to reason about, which is
why `Ingestion`'s rescue is written against the exception class and classifies by error
type rather than naming an index. Both routes are tested
(`two simultaneous creations of one subscription produce one subscription and one start`),
and the limitation is recorded in the migration, in `ingestion.rb`, in `AGENTS.md`, in
`CHANGELOG.md`, and here.

---

## 5. Migration reversibility, exercised

`test/models/outbox_processor_event_id_migration_test.rb`, 5 tests, 14 assertions. The
migration is taken **down and back up for real**, and the middle step is the one that
matters: with the index down the duplicate is writable, and with it up it is not, with
nothing else in the model changed between the two halves. That is what shows the constraint
is what refuses, rather than a model validation.

**It is a separate file for a safety reason, not a taste one.** Running a migration
**commits the enclosing transaction**, so a reversibility test inside `outbox_event_test.rb`
made every row it had written durable and broke *four unrelated tests* with counts one too
high. The separation is the safety property. This is the only file in the repository that
turns transactional tests off for this reason, and its `teardown` restores the index
unconditionally, because a failed assertion partway through would otherwise leave the index
down for the whole suite.

Proven by mutation: replacing `change` with `up` + a `raise IrreversibleMigration` in
`down` goes red on 3 of the 5.

---

## 6. Red/green, every direction

Every test shipped here was observed red, by removing the thing it tests. Nothing was taken
on trust from the `recover(...)` commit either, and **every row below was re-measured on
this branch** rather than copied forward from the previous worker's report.

| # | mutation | result |
|---|---|---|
| 1 | `stale?` uses `<=` instead of `<` | **RED** — 1 failure, `a delivery at the same processor timestamp is not stale` |
| 2 | the `stale?` guard call deleted | **RED** — 5 failures, incl. `Expected "past_due" Actual: "active"` and `a refused stale delivery does not clear a cancellation` |
| 3 | the outbox index removed **as a coherent unit** (migration + `schema.rb` + database) | **RED** — 2 failures + 1 error, headline `one Stripe event id produced 2 outbox rows… Expected: 1 Actual: 2` |
| 4 | `rescue ActiveRecord::RecordNotUnique` deleted | **RED** — 4 failures, the loser parked as `failed:` |
| 5 | uniqueness-`RecordInvalid` classification absent | **RED** — `Expected "ignored:duplicate_delivery"` / `Actual "failed:ActiveRecord::RecordInvalid: Validation failed: Processor subscription has already been taken"` |
| 6 | event id not merged into the body (3 helpers) | **RED** — 4 failures, `["evt_a","evt_b"]` vs `["evt_1PZQaBcDeFgHiJkLmNoPqR4"]`, and `every live status may be canceled` |
| 7 | `OutboxEvent.for_processor_event` pointed at the wrong jsonb key | **RED** — 2 failures, the scope can no longer find the row the index protects |
| 8 | migration made irreversible | **RED** — 3 errors, `ActiveRecord::IrreversibleMigration` |
| 9 | **the index itself, as shipped** | **RED on three *pre-existing* tests** — see §7b; test helpers had been lying about the delivery id |
| 10 | `uniqueness_race?` widened to "any `RecordInvalid`" | **RED** — the control fails, naming the consequence rather than the diff |

Each restored and re-run green.

### Row 3 has a trap in it worth naming

**Dropping the index from the database is not a reliable way to prove anything about
this fix.** `rails test` calls `maintain_test_schema!`, and when `schema.rb` and the
database disagree it reloads the schema — silently putting the index back. I hit this: the
first attempt at row 3 produced a **green** run with the index provably absent from
`pg_indexes` beforehand, which is a tripwire that reports nothing.

The fix has to be removed as a coherent unit instead — the index line out of `schema.rb`
**and** the database rebuilt from it — and the absence confirmed on both sides of the run.
A second process also had to be ruled out, which is §6b.

## 6b. A measurement I had to throw away, and the rule it adds

Mid-packet `lifecycle_test.rb` reported **1 failure and 30 errors** — `Processor has
already been taken`, `SoleRecordExceeded`, `Expected "canceled" Actual: "active"` — and the
new index looked guilty. It was not.

A second `rails test` process was running in the same worktree against the same per-worker
database. `AGENTS.md` already says that is not safe; what is new here is that **the
symptom is indistinguishable from a real regression** — 30 errors that all read as "the new
constraint broke the suite", on a suite that is entirely fine. The same file, alone, on
its own database: **77 runs, 137 assertions, 0 failures, 0 errors, 0 skips**. Every gate
number in §7 was taken on a private database for the same reason.

The rule this adds, and it is cheap: **when a suite suddenly fails in a way that
implicates a new constraint, look for a second suite before believing it.** The
per-checkout database name separates worktrees from each other, not two processes inside
one worktree from each other.

---

## 7. The gate — pass and skip counts reported separately

Measured on this commit, `PARALLEL_WORKERS=1`, `CI=true` (so eager loading is on), with
`CORE_PATH` set, **on a private per-packet database** — see §6b for why that is stated
rather than assumed:

| tier | result |
|---|---|
| whole suite (`bin/rails test`) | **851 runs, 2368 assertions, 0 failures, 0 errors, 0 skips** |
| contract (`test/contract`) | 45 runs, 400 assertions, 0 skips |
| webhook tier (5 files, now including `concurrent_delivery_test.rb`) | 162 runs, 390 assertions, 0 skips |
| money-path coverage (`money_paths_coverage_test.rb`) | 5 runs, 11 assertions, 0 skips |
| rubocop | 98 files, no offences |
| brakeman | 0 warnings |
| bundler-audit | no vulnerabilities |

**Passes: 851. Skips: 0.** Reported as two numbers rather than one line, because a skip
that reads like a pass is the failure this project has refused three times.

**The contract tier was measured both ways on this commit**, so the skip number is a
measurement rather than an assumption:

| `CORE_PATH` | `test/contract` | whole suite |
|---|---|---|
| a core checkout | 45 runs, 400 assertions, **0 skips** | 851 runs, 2368 assertions, **0 skips** |
| pointing at nothing | 45 runs, 61 assertions, **19 skips** | 851 runs, 2025 assertions, **20 skips** |

Same run count, same exit code, and **343 assertions of contract checking silently not
done**. That is the whole reason the gate sets `CORE_PATH` and fails on a single skip.

`BASELINE_RUNS`/`BASELINE_ASSERTIONS` and the webhook-tier count are raised **in the commit
that changed the tests**, as `AGENTS.md` requires — 763/2100 on master, 823/2299 in the
first commit here, **851/2368 in this one**. The `gate` job's own summary-parsing step was
replayed against a real run log to confirm it agrees.

**Stability.** `concurrent_delivery_test.rb` was run **6 consecutive times** on the final
code: 12 runs / 28 assertions / 0 failures / 0 errors / 0 skips, every time. That is a
result rather than an accident, and it is the direct consequence of fixing the 3-in-60
classification flake described in §7c — before that fix the same file failed roughly one
run in five, and six green runs in isolation would have been luck.

**The trap in mutation 3, because it produced a green run that meant nothing.**
Dropping the index from the database with `remove_index` does **not** prove anything:
`rails test` reloads `db/schema.rb` whenever it and the database disagree, silently
restoring the index. I hit exactly that — a "green" mutation run while `pg_indexes`
showed the index absent. The index has to be removed as a coherent unit (migration,
`schema.rb` and database) or not at all, and the red has to be read from a run that
really ran against the database you think it did.

**The race test is now in the `gate` job's webhook tier**, not only counted in the whole
suite. A regression test that exists only inside a total is one deletion away from being
decorative.

---

## 7b. The constraint found a second bug: three test helpers were lying

Worth its own section, because it is the argument for having built the constraint
rather than reasoning about the race.

After the index went in, **three pre-existing tests went red** — not the race tests, the
longstanding ingestion, lifecycle and subscription-delivery specs:

```
Webhooks::IngestionTest#test_two_different_event_ids_of_the_same_type_are_two_events
  Expected: 2
  Actual:   1
Subscriptions::LifecycleTest#test_every_live_status_may_be_canceled
  Expected: "canceled"
  Actual:   "active"
```

Both helpers called `ingest(payload, event_id: "evt_a")` and left the **body's** own `id`
at the fixture's. So they delivered under an id the payload did not carry. Production
cannot produce that — `stripe_controller.rb` passes `event_id: payload["id"]`, and the
controller's own line `payload.merge("id" => event.id, …)` overwrites whatever the body
claimed, so the delivery row and the payload always name the same event.

`Webhooks::StripeEvents.provenance` reads `payload["id"]`, so the emitted event was
stamped with the **fixture's** id no matter which id the test delivered under. Every
`billing.subscription.updated` in `every live status may be canceled` claimed to be the
same event, and the new index correctly refused the second one. The constraint was
refusing an input the controller could never send — which is the signature of a test
helper that had drifted from the code.

**All three helpers now merge the event id into the body**, mirroring the controller
(`payload.merge("id" => event.id, "type" => event.type)` at `stripe_controller.rb:86`, so
the id that reaches `Ingestion` and the id in the body are the *same* value by
construction), and new tests in two of the three files pin the invariant so a future helper
cannot drift back. This is a change to tests only; no production behaviour changed, and
nothing was weakened to make a test pass.

A **third** helper had the same defect and surfaced in the full-suite run rather than in
isolation: `subscription_delivery_test.rb`'s `deliver`. Fixing it changed which refusal
fires, and the change is worth recording because it is a real distinction rather than a
test that had to be adjusted:

```
SubscriptionDeliveryTest#test_a_fresh_event_id_reporting_the_state_we_already_hold_emits_nothing
Expected: "ignored:no_change_to_record"
  Actual: "ignored:stale_delivery"
```

The helper re-delivered the *same* `customer.subscription.created` fixture under a new
event id while leaving the body's `created` timestamp at the fixture's. So both
deliveries carried the **same processor timestamp**, the row's
`last_processor_event_at` equalled the new delivery's, and `stale?` — which is
**strictly** older, deliberately — did not fire; `no_change_to_record` did. With the id
moved into the body the case is what it claims to be: a fresh id reporting state already
held. The assertion is unchanged and now passes for the right reason.

That is the stale guard behaving exactly as its comment says, and it is a good argument
for keeping it: it refuses only what is *strictly* older, so a same-timestamp redelivery
falls through to the no-change rule rather than being refused as stale.

---

## 7c. The rescue had to be wider than the first version, and the measurement said so

The first version of the fix rescued `ActiveRecord::RecordNotUnique` only. When the
subscription route was added I wrote a comment naming
`subscriptions.processor_subscription_id` as "the" constraint on that path — and then
measured it, by running the two deliveries 60 times and recording which constraint
actually refused:

**57 refused by the unique index, 3 refused by the model's `validates … uniqueness`.**

Both are the same fact told two ways, and *which one a losing thread hears is a
scheduling accident*. A thread that reads the committed row gets the validation; a
thread whose insert collides gets the index. So a rescue on the exception class alone
would have parked roughly **one duplicate in twenty** as a failure — a row in front of a
human, for an event that is published and correct, five per hundred races, and
intermittent, which is worse than the bug it replaced.

`Ingestion#emit` therefore has a second branch:

```ruby
rescue ActiveRecord::RecordInvalid => e
  uniqueness_race?(e) ? webhook.ignore!(DUPLICATE_REASON) : park(webhook, e)
```

and `uniqueness_race?` asks the **error**, not the exception class:

```ruby
record.is_a?(ActiveRecord::Base) && record.errors.any? { |problem| problem.type == :taken }
```

`:taken` is the error type Rails' uniqueness validation raises. That is the only reason
the predicate is narrow, and narrowness is load-bearing: a `RecordInvalid` with no
uniqueness error in it is a bug in this service and belongs in front of a human. Two
tests hold it — one that a real uniqueness failure **is** recognised (so the branch is
not dead code) and one that a plain validation failure is **not** (so a bug cannot be
filed as a race and answered 200).

**Proven by mutation:** widening the predicate to `record.is_a?(ActiveRecord::Base)`
goes red on `a validation failure that is not a uniqueness race is still parked for a
human`, with the failure message naming the consequence rather than the diff. The
mutation is red on **three** tests, the third being a pre-existing one
(`a mapping to an event type the outbox does not list parks the row`) — which is the
clearest evidence that the predicate is load-bearing rather than decorative.

**And measured again afterwards, because "the flake is gone" is a claim:** the same 60
barrelled duplicate creations now record **60 `ignored:duplicate_delivery`, 0 parked, 0
duplicate subscriptions**. Sixty before and sixty after is the whole argument; ten green
runs in isolation would not have been an argument at all.

This is also why the comment in `ingestion.rb` deliberately does not name a single index:
I would have been writing down a claim that measurement then contradicted.

---

## 8. What I did not fix

1. **`billing.subscription.started` has no `processor_event_id` in its payload**, so the
   new outbox index is *not* a complete duplicate-suppression story for a future reader.
   A duplicate `customer.subscription.created` is refused on the `subscriptions` table
   instead — and, as §4 records, by a **model validation and a unique index together**
   rather than by either alone, with which one firing being a scheduling accident. That
   is correct today and tested from both sides, and it is more fragile than one named
   constraint would be. Closing the gap properly means putting the key in the start
   payload, which would change a **published event payload** — a contract change, and not
   this packet's to make unilaterally.
2. **A deployed table holding duplicates cannot take the migration.** A unique index cannot
   be created over data that already violates it. The duplicates must be resolved first.
   This is named in the migration, asserted in the test (the test deletes the duplicates
   and then rebuilds), and is a deploy step, not a code step.
3. **The stale-delivery guard does not and cannot cover concurrency.** Kept, because it
   covers a *different* case with a *different* key, but it is not part of this fix and
   should not be described as part of it.
4. **No publisher loop.** `published_at` is still always null. A duplicate is now prevented
   at the outbox, but nothing publishes, so this service still emits nothing to NATS. A
   later packet with its own brief.
5. **`/v1` is still unauthenticated.** billing-08's matrix now makes the gap total and
   queryable, which is not the same as closing it.
6. **The uniqueness classification is a heuristic, and it is deliberately narrow.** It
   treats *any* Rails `:taken` validation failure from a handler as a duplicate
   delivery, and a genuinely-taken record reached for some other reason would be
   recorded as `ignored:duplicate_delivery` rather than parked. That is the safe
   direction — the event is published, and the delivery is not redone — but it is a
   judgement, and the narrower alternative (rescuing only the two known columns) would
   be a list to keep in step with the schema. The alternative I rejected is worse: a
   blanket `RecordInvalid` rescue would swallow a real mapping bug and answer 200.
7. **The subscription route's duplicate suppression is still a race between two
   mechanisms** (a model validation and a unique index) rather than one constraint, and
   making it one is a schema decision this packet does not get to take. §4 has the
   measurement; §2 has the classification that makes the outcome consistent whichever
   one wins.

---

## 9. Housekeeping

- **Secrets.** `secrets_do_not_leak_test.rb` was checked and **does assert** — 10 tests
  capturing real log output from the failure paths, asserting a processor key, a signing
  secret, the signature header and a customer email are all absent. Every value in it is a
  literal that is a credential for nothing. No secret was added, logged, or committed.
- **Two lint offences** the previous worker left in the new test files (a missing final
  newline, and a `def` with a record creation as a parameter default) are **fixed, not
  disabled**. `AGENTS.md` forbids a lint disable to make a build green.
- **`test/probe_test.rb` is gone**, and so is the assertion-free pattern it was. It printed
  diagnostics and had zero assertions — it inflated the run count and proved nothing, which
  is the "silent green" this project has refused three times. Its content became a real
  deterministic regression test. There is no third option and none was taken.
- **No code copied** from `moon/refs/` or any legacy app. Everything is written from
  scratch; the reference was behavioural only.
- **Nothing pushed.** No force-push, no rewritten history. The two commits are additive on
  `worker/billing-08`.
- **Database cleaned up.** See below.

### A note on the database, and one thing I could not control

The gate ran against the **local** PostgreSQL 18 on 5432, not the `billing08-pg` container
the previous worker used on 15408: the machine restarted mid-packet and that container did
not come back. Same engine major for everything the schema uses (`jsonb` expression
indexes, partial unique indexes, `gen_random_uuid()`, `CHECK` constraints), and the
advantage is that there is no cluster or volume to leave running — only a database to drop,
which I did.

**The suite cannot run under 8 parallel workers on this machine.** `pg-1.6.3-arm64-darwin`
segfaults in `connect_start` while Rails creates the eight per-worker databases, which is
the hang `AGENTS.md` already documents in its own words ("Observed in this worktree with
`pg-1.6.3-arm64-darwin` segfaulting in `connect_start`, which left the suite finished,
green, and un-exiting"). Every number in this report is from `PARALLEL_WORKERS=1`, which
`AGENTS.md` records as producing the same tests and assertions as eight workers. I did not
raise retries or lower anything to work around it; the gem is the problem, and it is not
this packet's to fix.
