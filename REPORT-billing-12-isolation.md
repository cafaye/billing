# REPORT — billing-12: tenant isolation for the money service

**Branch:** `worker/billing-12-isolation`, from master at `247a1f8` (billing-09's
race fix landed).
**Not pushed.** Push is not this packet's to do.

**No behaviour in `app/` changed.** The packet's deliverables are tests, this
report and a CHANGELOG entry. That is not a dodge — it is the finding: this
service has no account scoping to make load-bearing, so what it had instead was a
**total absence of measurement** over a surface whose whole product claim is
multi-tenant. Three real cross-tenant defects were found on the way and are
reported, not fixed, because each is a change to money and none can be
discharged inside this packet.

---

## 1. The count

| | |
|---|---|
| **Account-scoped routes** | **14** — read 4, list 3, write 3, update 4, delete 0 |
| **Account-scoped data accesses** | **33** in 31 methods, filed under 32 keys — read 12, list 9, write 7, update 5, delete 0 |
| **Tests added under `test/tenant/`** | **62** |
| **Negative tests, by operation** | **31** — read 15, list 4, write 3, update 8, delete 1 |
| — cross-account delivery, against Postgres | 12 — read 2, list 3, write 2, update 4, delete 1 |
| — cross-account HTTP surface, against Postgres | 13 — read 11, list 1, update 1 |
| — the three findings | 6 — read 2, write 1, update 3 |
| Structural tripwires about the enumeration | 20 |
| Bookkeeping tests about the test files (`meta:`) | 11 |
| **Operation kinds covered** | **4 of 4** — read, list, update, delete (delete: one negative test over zero entry points) |
| **`403` responses found on an invisible resource** | **0** |
| **`403` responses added** | **0** |
| **Cross-tenant defects found, reported, not fixed** | **3** |
| **Mutations run, each turning a test red** | **15** |
| **Suite** | 851 → **913 runs**, 2368 → **2598 assertions**, 0 failures, 0 errors, 0 skips |

**62 is the directory and 31 is the cross-account part of it.** The difference is
20 structural tripwires about the enumeration itself and 11 tests about the test
files (`meta:`). Each of the three numbers is asserted by the file it belongs to,
so none of them is a number in prose: `cross_account_delivery_test.rb` asserts its
own 12 and its per-operation tally, `cross_account_web_test.rb` asserts its 13,
`cross_account_findings_test.rb` asserts its 6, and the matrix asserts its 20 by
counting the entry points it classified.

Every number here is checkable by a reader, and most of them are *asserted* rather
than described:

| number | where it is held |
|---|---|
| 14 routes, 4/3/3/4/0 | `account_entry_point_matrix_test.rb`, derived from the router |
| 33 accesses, 31 methods, 32 keys | same file, derived from `app/` |
| read 12 / list 9 / write 7 / update 5 / delete 0 | same file, tallied from the source |
| 12 / 3 / 4 / 6 / 20 / 11, and the per-operation tallies | each file's own `meta:` tests, counted from test **method names** |
| 0 403s | `Problem::CATALOG` is frozen, and `app/` is scanned |
| 3 findings | counted from the findings file's own test names |
| 0 account-scoped queries | counted from `app/` — this is what every gap assertion is coupled to |

### A note on how the test counts are derived, because a `grep` gets them wrong

The obvious way to count these is `grep -c 'test "'`, and it reports **56** rather
than 62 — because `cross_account_web_test.rb` generates six of its tests from the
`ADDRESSED_BY_UUID` table, and six tests that exist in the run are not six lines in
a file. Every count here is taken from `public_instance_methods(false)` at **run**
time instead, for the same reason the entry-point matrix keys on the method rather
than the line.

### Why two numbers and not one

A **route** is a caller-facing operation: 14. A **data access** is one place in
`app/` that reads or writes a tenant's row: 33, in 31 methods. The layers
overlap — a route is served by a controller method that performs a data access —
so adding them would produce one larger number that means nothing. They answer
different questions:

* the route count is *"how much of the surface is a caller's to reach"*;
* the data-access count is *"how many places have to carry an account scope when
  identity's JWKS verification lands"*.

**The second is the one that is not done, and it is the one this packet is
about.** It is 33 and it is zero scoped.

### Why the derivation is per-method, and what the three counts really are

The obvious key for a source scan is `file:line`, and it is the wrong one:
inserting a comment renumbers every site below it and turns a documentation edit
into a red suite. The key is `path` + the **method** the access sits in, which is
the unit a reader thinks in.

There are then three numbers rather than one, and the two gaps between them are
the shape of the code rather than rounding:

* **more accesses than keys (33 > 32):** `Subscriptions::Lifecycle#customer` does
  **two** lookups — `Customer.find_by(id: cafaye_customer_id)` and
  `Customer.find_by(processor_customer_id:)` — under one description, because one
  row can be found by either identifier and a delivery may carry only one.
* **more keys than methods (32 > 31):** `Lifecycle#apply` **both** builds a row
  that did not exist and writes to the one that did.

Both gaps are asserted with a message naming what a change would mean, so neither
can move silently.

### Seven of the 33 are declarations, not executions

Two `belongs_to` on `Subscription` and five `scope`s on `Subscription` and
`OutboxEvent`. They are counted because **an association is a query and a scope is
a query**, and leaving a category out of an enumeration is how the enumeration
stops being one. A reader who wants only where a request actually reaches a row
has **26**, and the file says so.

A declaration counts only when its declaring class holds tenant data. That check
is on the **declaring class**, read out of the file, not on the path — and it
excludes `IdempotencyKey`, which has a `scope :expired` and is keyed on the
request's own idempotency key. Counting it would have quietly put a fourth model
in the tenant-data set and contradicted the three-model pin.

`OutboxEvent` needed its own list, `PAYLOAD_TENANT_MODELS`, and the distinction
is worth the extra constant: its rows carry an account **inside `data`** and the
table has no `account_id` column. That is precisely why the brief's "or outbox
events" answers as **three writes and no read by account** — and it is asserted,
along with `refute_includes OutboxEvent.column_names, "account_id"`, because the
column is what a future publisher loop would add and this file's row would go
stale the day it does.

---

## 2. What the negative tests are, and where they had to go

> **An account A operation reaches nothing belonging to account B, and gets the
> same answer as it would for something that does not exist.**

**They are not on the HTTP surface, and they could not be.** `/v1` has no caller:
no token means no account, so there is no "account A" to send a request as. A
wire-level *account A asks for account B's resource* is not writable today. That
gap is the recorded one, held by `contract/tenant_isolation_matrix_test.rb` and by
each controller's own header, and nothing in this packet pretends to close it.

What is available is closer to the money: **the account boundary in this service
is a fact in the data**, carried by `Subscription#account_id` and
`Customer#owner_id`, and it is enforced in three places. All three are exercised
with two real accounts.

### The boundaries that hold — asserted, not assumed

| what | kind | where |
|---|---|---|
| one customer per `(owner_type, owner_id, processor)` | read | `Customer`'s uniqueness validation |
| two accounts may each hold a **live** subscription on the **same** plan | read | the live-uniqueness index |
| an account cannot hold two live subscriptions on one plan | update | the same index, `RecordNotUnique` |
| …and a **cancelled** account can come back | update | the index's predicate |
| a subscription cannot be written against an account that is not its customer's | update | `account_is_the_customers_owner` |
| a user-owned customer cannot be billed | update | the same validation |
| the event a customer's creation publishes names **that** customer's account | write | `Customer#publish_created` |
| the event a delivery publishes names the account it **resolved** | write | `Lifecycle` → `OutboxEvent.publish!` |
| nothing reads an outbox row back by account | list | no route, no query, no column |
| a cursor carries a position and an identifier, nothing else | list | `CursorPaging#encode_cursor` |
| a cursor is a keyset and cannot widen the query | list | `CursorPaging#apply_cursor` |

Two of these are the case the whole packet is about, and both were chosen for a
reason worth naming:

* **Both accounts share one plan.** With a plan per account, `(account_id,
  plan_id)` would be satisfied by `plan_id` alone and a dropped `account_id` from
  the index would go unnoticed.
* **Two accounts share a Stripe customer id is *not* asserted as legal** — that is
  F2, and it is a defect.

### Absence, not refusal — proven, not promised

The brief's rule is that a cross-account request gets the same answer as a
request for something that does not exist, and that a `403` is an enumeration
oracle.

**There are 0 403s and adding one is out of scope, so the check is that this
service *cannot emit one*.** `Problem::CATALOG` is a frozen table; no entry has
the status 403, so there is no code path to render one. That makes the guarantee
a property of a **closed set** rather than of a review. A second assertion reads
`app/` for `403`, `forbidden` or `:unauthorized`, which catches a controller that
reached past the catalog. Both are proven by mutation (§5).

**The 404 half was already right, and is now pinned.** A resource that does not
exist and an identifier that *cannot* name one are the same answer, byte for byte,
on all three uuid-addressed resources and on the plan slug path:
`V1::BaseController#uuid_param!` decides before the query, and `render_not_found`
renders one fixed sentence with no branch on *why*.

One thing that came out of writing it: **`instance` is the request path, so a 404
does repeat the identifier it refused.** That is not an oracle — the identifier is
the caller's own input, echoed to a caller who already has it — and the test's
first draft asserted the opposite and was wrong. The assertion that replaced it is
the stronger one and the more useful: the 404 carries **exactly seven keys**, the
caller's own path, and **one fixed sentence**. A second `detail` saying "or it
belongs to another account" is the shape of a real oracle, and it now fails here.

### The gap, pinned as a tripwire that fires when it closes

Four tests assert that the surface is open — a customer readable by uuid, a
subscription readable by uuid, a customer **writable** by uuid, a listing that is
not scoped. They are green, because a red test advertising a known hole is how a
suite starts being ignored; each says precisely what is true.

Each is coupled to `account_scoped_queries`, a count of account-constrained
queries in `app/` that is **0 today**. The day scoping lands that count moves and
**all four fail**, with a message saying to rewrite them as 404s. That is the
direction that matters, and it is proven by mutation (§5, M3b): all four went red.

The write case is there because a read is a disclosure and a **write** to another
account's row is the expensive direction, and a reader of the matrix should not
have to take on trust that the read being open implies the write being closed.

---

## 3. The three findings

Reported, not fixed. Each is a change to money — a guard in `Lifecycle`, which is
the only writer of subscription state, or a migration — and none can be
discharged inside this packet without a decision that is not this packet's.

Each is asserted **as a finding**, so each test is a **tripwire for the fix**:
landing the fix turns it red with a message saying to delete it and replace it
(§5, M9/M9b/M9c). A finding test that survives its own fix is a test nobody will
trust next time.

### F1 — a delivery reassigns a live subscription between accounts

`Subscriptions::Lifecycle#apply` writes `account_id: customer.owner_id` onto the
row it is updating and **never compares it to the account already there**.

Reproduced: a delivery creates `sub_FAKE…` against account A; a second delivery
for the same processor subscription id, naming B's customer, moves it.

```
F1: a delivery naming a different customer moves the subscription between accounts
   -> account:            A  ->  B
   -> customer:           A  ->  B
   -> billing.subscription.updated published with account_id: B
   -> account A holds 0 subscriptions; account B holds one it never bought
```

**The existing guard does not catch it, and the reason is the interesting part.**
`Subscription#account_is_the_customers_owner` *does* compare an account against a
customer, and it is the only such check in the service. It still passes: the new
account really does belong to the new customer. What it cannot see is that the
account **changed**, because the rule it enforces is *"a subscription's account is
its customer's"*, not *"a subscription's account does not move"*.

**What it costs.** The first account loses the subscription; the second gains one
it never bought; the `billing.subscription.updated` event carries the new account,
so a consumer counting plan changes or rendering an account's billing timeline is
told this was always the arrangement. The row stays `live` throughout, so a
consumer checking "is this subscription active?" sees an active subscription for
an account that never paid — `grants_entitlements?` is decided by status, and a
reassignment does not change the status.

**On its own, F1 needs a processor that sends a disagreeing delivery**, and a
well-behaved one does not: one `sub_` has one `cus_`. **F2 is what makes it
reachable through this service's own surface.**

### F2 — `customers.processor_customer_id` is not unique, and the API lets a caller set it

The column carries no unique index. `POST /v1/customers` and
`PATCH /v1/customers/:id` **both permit it**, and `Lifecycle#customer` resolves it
with `find_by`.

```
F2: a client can point its own customer row at another account's Stripe customer id
   -> PATCH /v1/customers/{attacker's own row} {processor_customer_id: <victim's cus_>}
   -> 200
   -> 2 rows now answer to that one cus_ id
```

So two accounts can hold customer rows answering to the same `cus_`, and from then
on a delivery about the victim's subscription may resolve to the **caller's** row —
and F1 does the rest. This is why F2 is worse than F1 rather than beside it.

**The lookup has no `ORDER BY`, so which account a delivery lands on is not
decided by the data.** That is asserted rather than avoided: the test pins the
two candidates and that `find_by` returns one of them, and **deliberately does
not assert which**. Pinning it would be a test of PostgreSQL's mood and a flake on
a different plan on a different day. The ambiguity *is* the finding.

`CustomerUpdate` closing `owner`/`processor` and permitting `processor_customer_id`
is otherwise right — those two are the key the uniqueness rule is built on — which
is exactly why this one column is the whole attack surface.

### F3 — `plans.processor_price_id` is not unique

The same shape one table over: no unique index, `POST`/`PATCH /v1/plans` both
permit it, `Lifecycle#plan` resolves it with `find_by`.

This one is a correctness defect rather than a tenancy one — a plan is catalogue
and the catalogue is shared on purpose — but the consequence is the same shape: a
subscription is billed against whichever plan claimed the id, at a price this
service did not agree to with the customer, and `billing.subscription.started`
carries that plan's currency and nothing about the one intended. The test pins two
plans claiming one id **charging different amounts**, so resolving to the wrong one
is a pricing defect rather than a cosmetic one.

### What each one needs

* **F1:** a comparison in `Lifecycle#apply` — refuse a delivery whose resolved
  account differs from the row's — recorded as a `Refused` reason alongside the
  existing six, so the delivery row carries it and the endpoint still answers 200.
* **F2, F3:** a unique index. Both columns are nullable and many rows legitimately
  are, so a `unique` index works without a predicate; a partial one would be
  equivalent here and is the more explicit statement of intent.

None of the three is fixed here, and `app/` is byte-identical to `247a1f8`.

---

## 4. Two accounts, and a digest so a failure cannot leak one

`test/support/two_accounts.rb` holds the two accounts every spec compares against,
because a negative test only means something if the **same** two accounts are on
both sides of every comparison, and an id that drifts between two files is a
comparison that quietly stops being one.

**Every processor id is obviously fake** — `cus_FAKE…`, `sub_FAKE…`,
`price_FAKE…`, `evt_FAKE…` — and the two account uuids are the constant
`1111…`/`2222…` pair, which is not a value anything mints. A fixture that looks
like a captured production value is a fixture somebody could paste somewhere it
does not belong.

**`TwoAccounts#fingerprint` exists because the specs must be able to say "this row
did not change" without printing the row.** The obvious way to write that is to
compare the records, which on failure dumps a whole other account's subscription,
price and status into CI output. A `sha256` per row says *byte-identical* without
saying what the bytes were, and `drifted_ids` then names **which** ids moved
rather than what they held. It is a hash keyed by id rather than one digest over a
set, because "did anything move" and "which rows moved" are two questions and only
the first works with a single value.

The HTTP specs go the same way: the disclosure assertions use `include?` with a
sentence in the message rather than `assert_includes body, sentinel`, which would
print the body — which on that surface is the other account's billing data. The
sentinel is a made-up address on the reserved `.invalid` TLD, and two sentinels
exist because **writing a row the value it already holds is a no-op**, and a no-op
cannot distinguish "the write reached the other account" from "the write reached
nobody".

No token, key or JWT is logged or printed anywhere in this packet; the only
signing secret in play is the suite's existing `whsec_test_only_signing_secret`,
a credential for nothing.

---

## 5. Red/green, every direction — 15 mutations, all red

A tripwire that has never been seen red is a check that has never been tested.
Every guard above was mutated; the table is the output, not a claim.

```
RED  M1  unclassified data access appears in app/
        -> every_data_access_in_app_is_an_account-scoped_entry_point
        -> every_data_access's_kind_is_one_this_matrix_claims_for_that_method
        -> the_data-access_breakdown_is_read_12,_list_9,_write_7,_update_5,_delete_0
RED  M2  a classified entry point's method is removed
        -> every_entry_point_this_matrix_classifies_is_one_the_source_still_has
        -> there_are_33_…_in_31_methods,_filed_under_32_keys
RED  M3  an unclassified account-scoped scope appears  (scope :for_account)
        -> every_data_access_in_app_is_an_account-scoped_entry_point (+3 more)
RED  M3b ... and the tripwire that says scoping landed
        -> all four gap: characterisation tests, at once
RED  M4  app/ grows a destroy
        -> delete_is_zero_in_app,_and_the_router_serves_no_DELETE_under_/v1
RED  M4b ... and the behavioural delete assertion
        -> delete:_there_is_nothing_to_scope,_because_this_service_destroys_nothing
        -> meta:_delete_is_one_negative_test_over_zero_entry_points
RED  M5  Problem::CATALOG grows a 403
        -> read:_this_service_cannot_emit_a_403,… (+ the source scan)
RED  M6  a controller names a 403 directly
        -> read:_no_controller_renders_a_403_by_any_route
RED  M7  the 404 detail becomes specific
        -> read:_the_404_for_a_{customer,plan,subscription}_…_one_fixed_sentence  (x3)
RED  M8  Subscription's account guard is weakened
        -> update:_a_user-owned_customer_cannot_be_turned_into_an_account's_subscription
RED  M9  the F1 fix lands (account change refused)
        -> F1: both finding tests, saying to delete them
RED  M9b the F2 fix lands (unique processor_customer_id)
        -> F2: all three finding tests + the findings' meta count
RED  M9c the F3 fix lands (unique processor_price_id)
        -> F3: …+ both meta counts
RED  M10 apply_cursor starts naming a model
        -> list:_a_cursor_is_a_keyset,_and_a_keyset_cannot_widen_the_query_it_pages
RED  M11 the outbox gains an account_id column
        -> the_payload-carrying_set_is_the_outbox_alone,…

== 15 mutation(s) turned a test red, 0 did not
```

`app/`, `db/` and `config/` were restored from git after every mutation and the
tree is clean.

### The harness had two bugs of its own, and one of them was embarrassing

**The grep read the summary backwards.** minitest prints
`20 runs, 40 assertions, 5 failures, 0 errors, 0 skips` — the count comes *before*
the noun. The first version of the harness matched `failures?, [1-9]`, which
matches only a **zero**, so the first full run reported **0 of 13 mutations
turning a test red**. That is the exact failure mode this packet exists to
prevent, pointed at the harness: thirteen tripwires reported as untested when all
of them fire. Fixed to `[1-9][0-9]* (failures|errors)` and re-run.

**One mutation was ineffective and one test was genuinely wrong.**

* M9 was written as "the lifecycle resolves a customer differently" and did
  nothing — the change it made was a no-op. Rewritten to the mutation that
  actually matters, *the F1 fix*, which fires.
* `destroyable_entry_points` counted `\.destroy`, with a leading dot. The ordinary
  spelling of a destroy is a **bare** `destroy` inside a model method, so the
  pattern reported **zero for a model that has a destroy in a method of its own**
  — which is the shape a destroy actually arrives in. M4b is what found it: the
  matrix's `\bdestroy\b` went red and this file's `\.destroy` did not. Now a word
  boundary, and the comment says why.

### A guard that could not find its target

Two bugs in this packet's own test code, both of the shape the repository's rules
warn about, and both fixed rather than worked around:

* **`group_by` over a Hash** files every row under
  `path = [path, method, kind]` and leaves the lookup empty — so the
  "kind is one this matrix claims" check failed **all 33 accesses at once** and
  read like a total absence of classification rather than a broken predicate.
  `DATA_ACCESSES.keys.group_by`, not `DATA_ACCESSES.group_by`.
* **`for_processor_event` can never find a start event**, because
  `Lifecycle`'s start payload deliberately carries **no** `processor_event_id` —
  the same omission that makes the duplicate-creation index unreachable for a
  start. The honest lookup is the envelope subject, this service's own
  subscription id. (This is the trap AGENTS.md documents; it caught a test, not
  the code.)
* A regexp written against the *source string* of a test name rather than the
  **method name** — the `test` macro mangles `read: an account cannot…` into
  `test_read:_an_account_cannot…` — matched nothing and reported zero of
  everything, which reads as "this file has no negative tests".
* `fingerprint` returned a String and `drifted_ids` indexed it by id. On a String
  that is a **substring search**, `nil` for every uuid, so every row reported as
  drifted and the assertion was true on **every run, including the runs it exists
  to catch**.

---

## 6. The gate — pass and skip counts, separately

`bin/prime`, from a primed worktree:

```
== ruby ruby 4.0.1 (2026-01-13 revision e04267a14a0) +PRISM [arm64-darwin23]
== bundle install        Bundle complete! 15 Gemfile dependencies, 106 gems
== rails db:prepare
== rubocop               103 files inspected, no offenses detected
== rails test            913 runs, 2598 assertions, 0 failures, 0 errors, 0 skips
== prime ok (rails Rails 8.1.4)
```

| | before this packet | after |
|---|---|---|
| runs | 851 | **913** (+62) |
| assertions | 2368 | **2598** (+230) |
| failures / errors / skips | 0 / 0 / 0 | **0 / 0 / 0** |
| rubocop | 98 files clean | 103 files clean |

The +62 is exactly the four new files (20 + 18 + 16 + 8); the fifth new file,
`test/support/two_accounts.rb`, contributes no tests of its own.

**Security, no database:** `bundler-audit` — *No vulnerabilities found*
(1251 advisories, db updated). `brakeman --no-pager --quiet --exit-on-warn` —
`Errors: 0`, `Security Warnings: 0`, no warnings.

### The two environment-gated tiers, named and measured

Neither is gated on anything this packet introduced, and neither skipped — but
both are reported because a green run that did not notice them has checked less
than its line says.

**1. `test/contract/` — reads `core`'s real schemas, and skips 19 tests when
`core` is unreadable.** Measured here, same commit, same code:

| `CORE_PATH` | `test/contract` | whole suite |
|---|---|---|
| a core checkout (`../core`, on disk) | 45 runs, 400 assertions, **0 skips** | 913 runs, 2598 assertions, **0 skips** |
| pointed at nothing | 45 runs, 61 assertions, **19 skips** | 913 runs, 2255 assertions, **20 skips** |

**Same run count, same exit code, and 343 assertions of contract checking simply
not done.** (20 skips and not 19 because a twentieth reader of `core` sits outside
the contract directory — `integration/subscription_delivery_test.rb`, which is why
`CORE_PATH` is set on the CI *job* rather than on the contract step: a variable
set per step is a variable the second reader does not get.)

The suite's `0 skips` on this branch is therefore load-bearing: it is what says the
tier ran. `ci.yml`'s `gate` job sets `CORE_PATH` on the job and **fails the build
on a single skipped test**.

**2. `config.eager_load`, gated on `ENV["CI"]`.** `config/environments/test.rb`
sets `config.eager_load = ENV["CI"].present?`, so the suite eager-loads the whole
application in CI and not locally — "the application loads" is checked in CI by an
implicit convention. `ci.yml`'s `gate` sets `CI` explicitly and has a step that
fails if `eager_load` is false or if `eager_load!` loaded fewer files than
`app/**/*.rb` contains. **Locally this tier is off**, so a local green run says
nothing about it; the number of files it must load is unchanged by this packet,
which adds nothing under `app/`.

**`test/tenant/` needs no tier of its own, and that is a reason rather than an
omission.** A named tier exists for a test file that can *silently skip* — the
contract tier is named as a directory precisely because it hides behind that
skip. Nothing in `test/tenant/` reads `core`, reads the clock, or touches the
network; all 62 runs execute on any machine with a database, which is why they are
in the default tier and are counted in `BASELINE_RUNS`.

---

## 7. What I did not do

* **I did not add a 403.** The brief forbids it and there are none; the check is
  that none *can* be added without a test going red.
* **I did not add a 404 to make the open surface look closed.** Without a caller
  there is no other account, so a 404 would be a refusal of a legitimate request
  and would break every client while pretending to be a security fix. The four
  gap tests are green and say what is true, and they fire when scoping lands.
* **I did not fix F1, F2 or F3.** §3 says what each needs and why it is not this
  packet. `app/` is byte-identical to `247a1f8`.
* **I did not touch `bin/prime`, `docker-compose.yml` or `gate.yml`.** Another
  billing packet may own them.
* **I did not push.**
* **I did not add account scoping.** There is no token to scope by; it is a
  different packet and a breaking change to this surface, as three places already
  say.

### Two drifts in files I had to touch, noted rather than fixed

Both pre-date this packet. Both are **in** `.github/workflows/ci.yml`, which the
repo contract requires this packet to edit — the `gate` job is red until
`BASELINE_RUNS` is raised in the same commit as a new test.

1. **The header's itemisation does not add up.** The three per-packet deltas
   (45 + 7 + 34 − 1) sum to 85 against a claimed `763 → 851`, and billing-08's
   claimed `45 / 99` does not match its own bullets. The asserted **totals** are
   right; it is the prose that has drifted. Correcting the prose about a threshold
   is a separate job from raising the threshold, and this one raised — so the
   drift is **noted in the file** rather than silently propagated, which is how it
   survived this long.
2. **The webhook tier's step name says 147; the assertion below it says 162** —
   and `bin/rails test` on those five files prints `162 runs, 390 assertions`.
   This one I **did** correct, because it is a number, the assertion beside it is
   the number, and I had to read the file to find out what the tier asserted.

---

## 8. Housekeeping

* Branch `worker/billing-12-isolation`, from master at `247a1f8`. **One commit,
  not pushed.**
* New: `test/tenant/account_entry_point_matrix_test.rb` (20),
  `test/tenant/cross_account_delivery_test.rb` (18),
  `test/tenant/cross_account_web_test.rb` (16),
  `test/tenant/cross_account_findings_test.rb` (8),
  `test/support/two_accounts.rb` (0).
* Changed: `CHANGELOG.md` (`### Added` at the top of `[Unreleased]`, plus the CI
  baseline entry), `.github/workflows/ci.yml` (baseline raised to `913 / 2598`,
  the `+62 / +230` itemisation, the two drift notes), `AGENTS.md`.
* **Unchanged: every file under `app/`, `db/`, `config/`, `lib/`, `bin/`, `openapi/`,
  `cafaye.yml`, `Gemfile.lock`, `docker-compose.yml`, `mise.toml`.**
  `git status` on those paths is clean.

### A note on the local database

The worktree's `docker compose up -d` could not bind 5432 — a Homebrew PostgreSQL
18.4 already held it on this machine. The suite ran against that instance, which
is what `config/database.yml` uses by default (no `host`, no `username`, so the
OS user `kaka`). The per-checkout database name — `worker_billing_12_isolation_test`
— came from the worktree's directory as that file's comment intends, so this run
shared no database with `billing/` or with `billing-worker-billing-10-gate`.

**One consequence worth naming: this was PostgreSQL 18, not the pinned
`postgres:17-alpine`.** `docker-compose.yml` pins 17 and CI uses 17, and this run
was **not** on 17. Nothing in the packet depends on the difference and I checked
rather than assumed — the whole packet is row lookups by uuid, a partial unique
index, and `order(created_at:, id)` on a `timestamptz` and a `uuid`, and
`docker-compose.yml`'s own note records that no ordered read in this repository
sorts a text column. But it is a difference from the pin and it should be said
rather than buried.
