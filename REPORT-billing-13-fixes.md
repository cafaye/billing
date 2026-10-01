# REPORT — billing-13: F1, F2, F3 fixed

The three cross-tenant defects `REPORT-billing-12-isolation.md` proved are closed.
`+37 runs / +126 assertions` (913 → 950 runs, 2598 → 2724 assertions),
`0 failures / 0 errors / 0 skips`, and no secret, key or token is logged or printed
anywhere in this packet.

**The brief's acceptance criteria are billing-12's own tests.**
`test/tenant/cross_account_findings_test.rb` is where each finding was asserted, so
each finding is now asserted *there* — the same two accounts from
`test/support/two_accounts.rb`, the same `customer.subscription.updated` delivery
naming the other account's customer, the same `PATCH` on a caller's own row
carrying a victim's `cus_`, the same pair of plans charging different amounts. The
**setup is unchanged. Only the assertion changed**, from "the defect reproduces" to
"the defect is refused". They are rewritten, not deleted, and §5 says why that is
the point.

---

## 1. F1 — a delivery can no longer move a subscription between accounts

**The fix, where the report said to put it:** a comparison in
`Subscriptions::Lifecycle#apply`, recorded as a new `Refused` reason beside the
existing six.

### Before

`apply` wrote `account_id: customer.owner_id` onto the row and **never compared it
to the account already there**. A second delivery naming another account's customer
moved a live subscription, and published the move:

```
F1: a delivery naming a different customer moves the subscription between accounts
   -> account:            A  ->  B
   -> customer:           A  ->  B
   -> billing.subscription.updated published with account_id: B
   -> account A holds 0 subscriptions; account B holds one it never bought
```

### After

```
F1: a delivery naming a different customer is refused
   -> ignored:account_mismatch          (on the delivery row)
   -> HTTP 200
   -> account:            A  ->  A      (unchanged)
   -> customer:           A  ->  A      (unchanged)
   -> no billing.subscription.* event published
   -> account A still holds its live subscription; account B holds nothing
```

`ACCOUNT_MISMATCH = "account_mismatch"`, and the guard is one line in `apply`:

```ruby
raise Refused, ACCOUNT_REASON if existed && !same_account?(subscription)
```

**Three things about that line, each of which is load-bearing and each of which was
proven by a mutation (§4).**

* **Before `assign_attributes`,** which is the statement that overwrites the
  account. A comparison made afterwards compares the new account with itself and
  always agrees. Mutated: the guard still runs, and still passes, and 5 tests go
  red.
* **Only when the row existed.** A creation has no account to disagree with, which
  is the whole of the deletion-arriving-before-its-creation rule. Mutated by
  dropping `existed &&`: 9 pre-existing tests plus 3 new ones go red.
* **Compared against the row, not against the customer.** This is the comparison
  the model could not make.
  `Subscription#account_is_the_customers_owner` enforces *"a subscription's
  account is its customer's"* — and after a reassignment that is **true**, because
  the new account genuinely belongs to the new customer. The rule has no opinion
  about the account **changing**, so the write was internally consistent and
  cross-tenant simultaneously. `Subscription`'s own validation passing is why this
  survived billing-12's negative tests, and it is why the guard had to go in the
  only writer of the row.

### The 200 is part of the fix, and it is asserted over HTTP

A refused delivery is a **decision**, not an error. The row carries the reason, a
human reads it there, and the endpoint answers 200: a 5xx or a 4xx would tell the
processor to redeliver a delivery that reaches the identical conclusion every time.

`test/tenant/`'s helpers call `Webhooks::Ingestion` directly, so the status is
asserted at the HTTP edge in `test/integration/stripe_webhook_test.rb`, where the
signature path is real. The fixture's `updated` event is a week later than the
`created` one, so `stale_delivery` cannot be what refuses it — the account
comparison is.

### Where it sits in the order, and why

After the state machine, after `no_subscription_to_update` and after
`stale_delivery`. Those are the rules a subscriber is relying on and none of them
should be reported as something incidental. A delivery that is both out of order
*and* cross-account is recorded as the out-of-order one, which is the honest
reading of that row.

### One thing I did not write, and why

A guard for "both accounts absent" would be **unreachable code**.
`subscriptions.account_id` and `customers.owner_id` are both `null: false`, so
"both unknown" is not a state this table can be in. I wrote that guard first, then
found the columns and removed it — the same rule `AGENTS.md` already states about
`Subscription#account_id` carrying no shape validation, for the same reason. A nil
account is refused at the edge instead: the column's `NOT NULL` for a write that
skips the model, and the presence validation for one that does not. The comment on
the method says so, so the next reader does not add it back.

---

## 2. F2 — one Stripe customer id, one customer row

### Before

```
F2: a client can point its own customer row at another account's Stripe customer id
   -> PATCH /v1/customers/{attacker's own row} {processor_customer_id: <victim's cus_>}
   -> 200
   -> 2 rows now answer to that one cus_ id
   -> Lifecycle#customer resolves it with find_by, no ORDER BY
   -> which account is billed is NOT decided by the data
```

### After

```
F2: the same PATCH
   -> 409 conflict
   -> detail names processor_customer_id
   -> 1 row answers to that cus_ id
   -> the caller's own row is byte-identical (fingerprint, unchanged)
   -> find_by now has exactly one answer, and the data decides it
```

### Plain or partial index, decided

**Partial: `where "processor_customer_id IS NOT NULL"`.** Four reasons, in the
order they actually decided it.

1. **The rule is about the value, not the column.** The column is nullable and
   legitimately so: a customer created through `POST /v1/customers` has no `cus_`
   until its first subscription tells this service what the processor calls it,
   and `Lifecycle#customer`'s own comment says so. Many rows are legitimately in
   that state at once. *"A value here is unique"* is the statement; *"this column
   is unique"* is not true and would be wrong to write.
2. **A bare `unique` index would work — by accident, and on someone else's
   promise.** It would allow the nulls because PostgreSQL defaults to
   `NULLS DISTINCT` and a null never equals a null. That is a **database default,
   not a statement of this service's intent**, and `NULLS NOT DISTINCT` is a
   PostgreSQL 15 feature a future migration could set on this column for an
   unrelated reason — and it would turn every `/v1`-created customer into a
   collision. The partial index has no such dependency: a null is not **in** the
   index, so there is no rule for it to satisfy or to break whatever the column's
   null semantics become.
3. **The house precedent is the same shape for the same reason.**
   `outbox_events_processor_event_id_idx` is partial, and the reasoning in
   `db/migrate/20260930000010_…` is that a key the value did not carry must not be
   constrained by a rule about keys that carry it. Two partial indexes, one
   principle.
4. **It is proportional.** The index carries an entry per row that actually claims
   a processor id, rather than one per customer forever to enforce a rule that does
   not apply to them.

**A deploy step, not a no-op.** A unique index cannot be created over data that
already violates it, so a deployed `customers` table holding two rows on one `cus_`
**has to have them resolved before this migration can be applied at all.** That
refusal is the database being correct. The same step is asserted as behaviour in
the migration test — the duplicates have to be deleted before `migrate(:up)` will
succeed — and the test's own teardown hit it: restoring the index before clearing
the rows failed on the file's own leftovers, which is the same refusal a deployment
meets. The teardown clears rows first, and says why.

---

## 3. F3 — one Stripe price id, one plan

### Before

Two plans could claim one `price_`, and `Lifecycle#plan` resolves it with
`find_by`. A subscription was then billed against whichever plan claimed the id, at
a price this service never agreed to with the customer, and
`billing.subscription.started` carried **that** plan's currency and nothing about
the one intended — so the wrong amount was not only charged but published.

### After

`plans_processor_price_id_idx`, unique over the non-null values, with the same
partial reasoning as F2 for the same reason (a plan is written through `/v1`
before it is ever put on sale). A colliding `POST` or `PATCH` is a **409 naming
`processor_price_id`**, and nothing is written.

The pricing half is asserted, not asserted-about: the two plans in the test charge
`1_900` and `49_000` minor units and the test says they must still differ, so a
collision here stays a money defect rather than becoming "a lookup might be wrong".
That survives a rollback of the index, which is what makes it a fact about the
fixtures rather than about the constraint.

---

## 4. Red/green, every direction — 8 mutations

A tripwire that has never been seen red is a check that has never been tested. Every
guard above was mutated, and the table is the output rather than a claim.

| # | mutation | result |
|---|---|---|
| **M1** | F1's guard deleted from `apply` | **6 failures** across `test/tenant/`, `lifecycle_test.rb`, `stripe_webhook_test.rb` |
| **M2** | comparison moved **after** `assign_attributes` | **5 failures** — the guard still runs and still passes, because it compares the new account with itself |
| **M3** | `existed &&` dropped | **9 pre-existing** creation tests + 3 new ones red, including deletion-before-creation |
| **M4** | both indexes dropped from every worker database | **5 failures, 6 errors** — including `meta: no resolution key is ambiguous`, and both migration files |
| **M5** | both model validations removed | **4 failures, 5 errors** — the 409s and the findings tests |
| **M6** | indexes present but **not unique** | caught — but **only after I moved the assertion**, see below |

**M2 is the one worth having.** A guard in the right method, with the right
condition, that compares the right two values, and still does nothing: because the
overwrite happens first. Only a mutation of the *position* finds that, and no
amount of reading the guard would have.

**M6 exposed a test that could not fail, which is the honest reason this section
is longer than three lines.** The assertion "the index is unique" lived in the
migration test file — and that file **rebuilds** the index, because it rolls it
back and up to prove the `down` works. So a non-unique index was repaired by
whichever test ran first, and the assertion passed against an index the migration
would never produce. **The test was green because of the order.** Two fixes, and the
second is the real one:

* Moving the reset from `teardown` to `setup` made it *worse* — now the file
  created the index immediately before reading it, so the assertion could never
  fail by construction.
* The observation moved to `test/tenant/cross_account_findings_test.rb`, which
  **observes and never repairs**. `unique_processor_id_indexes` filters on
  `index.unique`, so a drop to a non-unique index — the one mutation that leaves
  the rule documented and unenforced — fails by name. A guard that only ever
  rebuilds what it measures cannot detect a wrong thing about it.

**M4 and M5 together say something about the two constraints.** With the indexes
dropped and the validations in place, every request spec **stayed green** — the
validation alone refuses. With the validations removed and the indexes in place,
the request specs went red on the *body* assertion, not the status: the index alone
still yields a 409, but one whose detail names no field. Neither constraint is
sufficient to reason about, which is the same measurement billing-09 recorded for
`subscriptions` and the reason the API contract carries **both** a named 409 and a
constraint.

**One methodology note, because it nearly invalidated M4.** `test_helper.rb` calls
`parallelize(workers: :number_of_processors)`, so a run creates
`worker_billing_13_fixes_test_0` … `-7` and no two workers share a database. My
first M4 dropped the indexes from the **base** database and the suite stayed green
— the mutation had never reached a database the tests use. Every schema mutation
has to be applied to all nine. Worth knowing before believing a schema mutation
that reported nothing.

---

## 5. What the findings tests became

`test/tenant/cross_account_findings_test.rb` is 8 tests, was 8 tests, and the
fixture is untouched. billing-12 wrote them to *document* the defects, so each
asserted the defect was present and said in its failure message that landing the
fix should turn it red with an instruction to delete it. They are **replaced rather
than deleted**, and they are the same tests — the only change is the assertion's
direction. The names changed, because a test called *"a delivery naming a different
customer moves the subscription between accounts"* that asserts it did **not** is a
lie in the name, and the next reader would believe the first half. The `F1`/`F2`/`F3`
prefix is kept, so `declared_finding_labels` still derives the three findings from
the file rather than from a constant.

| test | was | now |
|---|---|---|
| `F1: …` | the row **moved**, `account_id` became B, an update was published | the row is **byte-identical** (`fingerprint`), still on A, `ignored:account_mismatch`, **no new event** |
| `F1: …` | A lost it, B gained it, still granting | A still holds it, B holds **nothing**, still live |
| `F2: …` | two accounts **hold** one `cus_` | the second write is refused, **`:taken` on the field**, count is 1 |
| `F2: …` the `PATCH` | `200`, and the attacker's row now claims the victim's id | **`409`**, the field is named, the row is **unchanged** |
| `F2: …` the ambiguity | `find_by` returns one of two, **deliberately not asserting which** | the second claimant **cannot be written**; the resolution is **single-valued** |
| `F3: …` | two plans **claim** one `price_` | the second is refused, **`:taken` on the field**, and the two still charge different amounts |
| `meta: …` | "two resolution keys are ambiguous" | **"no resolution key is ambiguous"** |
| `meta: …` | "the three findings are **reported rather than fixed**" | "still named, still reproduced, and F1's guard is on the lifecycle" |

**The `F2` ambiguity test is the strongest thing here.** billing-12 *deliberately
declined* to assert which account a `find_by` resolved to, and was right to: the
ambiguity was the finding, and pinning it would have been a test of PostgreSQL's
mood. After the fix there is one answer, so the assertion that could not be made
before can be: **the resolution is single-valued, and the data decides it.** That is
the same query, the same pair of accounts, and a stronger claim.

**The `meta:` test is deliberately the inverse.** It used to pin that two keys
*were* ambiguous — a count that had to drop to zero, a tripwire for the fix. It now
pins that **none** is, which is a tripwire for the *unfixing*. A guard that can
only be tripped in one direction is a test of a moment rather than of a property.
This is the assertion M4 and M6 actually hit.

**The indexes are not proved in `test/tenant/`, and cannot be.** These tests run
inside a transaction, and a `PG::UniqueViolation` aborts it, so a test here that
tried to show the *index* refusing would poison every assertion after it. That is
what the two migration tests are for, in files of their own because running a
migration commits the enclosing transaction. `test/tenant/` proves the **API
contract** — a caller who tries gets a refusal that names the field; the migration
tests prove the **constraint** — the database arbitrates.

---

## 6. The gate — pass and skip, separately

`bin/prime`, on this branch, from a clean worktree:

```
== rubocop
103 → 109 files inspected, no offenses detected

== rails test
950 runs, 2724 assertions, 0 failures, 0 errors, 0 skips
```

| | master (8bbbcec) | this branch |
|---|---|---|
| whole suite | 913 runs, 2598 assertions | **950 runs, 2724 assertions** |
| contract tier | 45 runs, 400 assertions | 45 runs, 400 assertions |
| webhook tier | 162 runs, 390 assertions | 163 runs, 396 assertions |
| money-path coverage tier | 5 runs, 11 assertions | 5 runs, 11 assertions |

**Skips: 0, in every tier, and separately confirmed rather than read off one
summary line.** The contract tier is the one that skips — it reads core's real
schemas and skips 19 tests when it cannot, which `AGENTS.md` records as *19 skipped
and 343 assertions of contract checking simply not done* under the same green exit
code. `../core` is a checkout beside this worktree, so it ran. The `security` job's
`brakeman --no-pager --quiet --exit-on-warn` is environment-free and was not run
here; `bin/prime` is the gate CI runs locally and in the `gate` job.

`BASELINE_RUNS`/`BASELINE_ASSERTIONS` are raised to 950/2724 **in this commit**, as
`AGENTS.md` requires. The workflow header's itemisation is rewritten rather than
appended to, and the prior history is kept below it.

### The one thing that inflated a tier, and it is a trap

The fixture drift-guard I wrote first lived at
`test/support/fixture_processor_ids_test.rb`, and it **inflated two CI tiers it had
nothing to do with**: the contract tier's 45 runs became 53 and the webhook tier's
150 became 159. `test_helper.rb` requires **all** of `test/support/**/*.rb`, so a
`_test.rb` file in `test/support/` is loaded into every tier that names any other
path. I found it because a tier's count moved and the file was not in the tier.

The file moved to `test/coverage/fixture_processor_ids_check_test.rb`, and the
workflow header now says so explicitly: **put a test in the directory of the thing
it tests.** `test/support/` is for modules, and a module there is what every other
test file is entitled to load.

While measuring that, the webhook tier's step asserted five files' worth of tests
(162) while listing four. `concurrent_delivery_test.rb` reaches the tier through
the same `test/support/**` require, not by being listed — measured both ways on this
branch: the four listed files are 151/368, the five are 163/396. The number that
gates is the five, and the workflow now says so instead of leaving the reader to
work out which five.

---

## 7. Two test helpers that were quietly arranging the defects

**No existing webhook test broke, and requirement 3's condition did not arise.** No
webhook test was encoding the defect, so none was fixed on that basis. The full
suite after the `app/` change alone was green on every delivery, ingestion and
concurrency test. The two files that did move are these, and both for the same
reason.

`create_stripe_plan` and `create_stripe_customer` in
`test/support/stripe_subscription_fixtures.rb` defaulted to **one** `price_`/`cus_`
each, so a spec asking for two customers or two plans got **two rows claiming one
processor id**. That is F2 and F3's exact shape, arrived at by accident. Nothing was
*arranging* a collision; it was an artifact of a shared default, and the two new
indexes turned **85 passing tests** in `test/requests/v1/subscriptions_test.rb`
into 85 `PG::UniqueViolation` errors, plus 1 in `test/models/subscription_test.rb`.

**The fix is the default, not 85 call sites.** The first call in a test still gets
the committed fixture's id, because that id is load-bearing: it is what
`test/fixtures/stripe/customer.subscription.*.json` carry and what every delivery
resolves through. Later calls get a distinct obviously-fake id. And a separate
euro-currency plan in that file was claiming the **USD plan's** `price_` — which is
incoherent on its face, since one Stripe price cannot be both — and now has its own.

`FakeStripeAPI::KNOWN_PRICES` is a **closed list**, and it is what makes "the
processor said no" arrangable, so a plan's price has to be one the fake knows. That
is a real coupling between two literals, held together by
`test/coverage/fixture_processor_ids_check_test.rb` rather than by a comment — it
cannot be structural, because the fake loads before the fixtures module.

**One test in `test/models/subscription_test.rb` was arranging it too.** Its
`create_customer` helper hardcoded one `cus_`, and
`test "a second account may hold the same plan at the same time"` builds two
customers — refused for holding an id the first already had. The helper now counts.

---

## 8. A shared savepoint, and a report on what I did not do

`test/models/outbox_processor_event_id_migration_test.rb` was the only test needing
the savepoint trick (a uniqueness violation aborts the transaction, so
`requires_new: true` absorbs it) and carried it privately. billing-13 adds two more
constraint tests, so the trick would exist three times — and a subtly wrong copy
produces a test that reports "the index refused" when the **savepoint** was what was
measured. It is now `test/support/constraint_refusals.rb`, included for all three.
That is a change to a file this packet did not otherwise need to touch, and it is
the only place I edited outside the findings, the new tests and the docs.

**Not done, and named rather than left to be discovered:**

* **`/v1` is still unauthenticated and still unscoped.** 14 account-scoped routes
  and 33 data accesses still carry **zero** account scopes. F1, F2 and F3 close the
  *delivery path*'s resolution being ambiguous and movable; they do not authorize
  anybody, and they are not a substitute for scoping. `account_scoped_queries` is
  still 0, and the four `gap:` tripwires in `cross_account_web_test.rb` still pin
  the open surface.
* **The deploy step for both indexes is real** and is §2's. A table already holding
  the duplicates cannot be migrated, and nothing in this branch resolves them for
  you.
* **`NULLS NOT DISTINCT` robustness is argued, not tested.** The null-rows test
  proves repeated nulls are permitted; it does **not** prove the index is partial,
  because a bare `unique` index would pass it too under `NULLS DISTINCT`. The
  comments in both migration files now say exactly that, so nobody reads the test
  as more than it is.
* **No push.** The branch is `worker/billing-13-fixes` and nothing left this
  worktree. No token, key or JWT is logged or printed; every processor id is
  `cus_FAKE…` / `sub_FAKE…` / `price_FAKE…`, and the two ids that are *not* fake are
  the committed fixtures' own, which a test asserts they still are.
* **No sleeps, no raised retries, no loosened assertions.** The migrations and
  their tests are deterministic throughout: the database arbitrates, and the
  reversibility proof is `down` → the duplicate becomes writable → `up` → refused
  again, with no interleaving and no waiting.
