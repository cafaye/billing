# REPORT-billing-21 — authorization on `/v1`

**Branch** `worker/billing-21`, from `7251993` (billing-11 merged). **Nothing is
committed, pushed, merged or tagged** — the work is in the worktree.

`bin/prime` exits **0**: `1077 runs, 3064 assertions, 0 failures, 0 errors,
0 skips`, `127 files inspected, no offenses detected`, and the tree is
byte-identical afterwards. `brakeman` reports **0 security warnings**;
`bundler-audit check --update` reports **no vulnerabilities** against 1251
advisories.

---

## 1. Does a tenant concept exist?

**Yes, and it was already here — nothing had to be invented.** billing-12
enumerated it and the finding was that no query was *scoped* by it, not that the
concept was missing:

| | |
| --- | --- |
| `subscriptions.account_id` | a uuid column, not null in practice, written by the lifecycle from `customer.owner_id` |
| `customers.owner_type` + `customers.owner_id` | a polymorphic owner, `("Account", <uuid>)` or `("User", <uuid>)` |
| `plans` | **no account column at all** — a plan is the platform catalogue, deliberately |

`Identity` is the type in `core`'s tenancy vocabulary and this service already had
two of the three columns. What billing-21 added is `for_account` on the two models
that have one, and the `catalogue` verdict for the one that does not.

The fleet checker disagrees that this is declared rather than inferred, and it is
right — see §5.

---

## 2. What was built

### The lock

`AuthenticatesPrincipal` is a `before_action` on `V1::BaseController`, not a
middleware and not a path check. `Webhooks::BaseController` does not inherit it,
cannot reach it, and `raise_on_missing_callback_actions` stops a future controller
in that namespace from skipping the filter by not naming an action.
`test/authentication/principal_lock_test.rb` reads the boundary **from the
router's own table**, so it is the route set that is checked and not a list of
paths in a comment.

| condition | status | why that one |
| --- | --- | --- |
| no token, or one this service refused | **401** `unauthorized` | the caller's credential |
| no issuer or audience configured | **503** `unavailable` | **ours** — a 401 sends the operator to the wrong system |
| identity's JWKS unreachable | **503** `unavailable` | we cannot check the credential right now |
| another account's resource | **404** | absence, never refusal — a 403 is an enumeration oracle |

**Fail-closed is the property the packet exists for.** There is no branch in the
concern that lets a request through without a verified principal: no default
account, no "auth is off in development", no rescue that renders a 200. An unset
`BILLING_IDENTITY_ISSUER` locks `/v1` rather than serving it, and that is tested
by deleting the environment rather than by faking a constructor argument.

### The verifier

`app/services/identity/token_verifier.rb` is the only place a JWT is read in the
repository, and a test **scans `app/` and `lib/` to keep it that way** (§4).

- **RS256 pinned as a constant, checked on the token's own protected header before
  anything is fetched.** `alg: none` and an HS256 token signed with the published
  public key both die without a network call.
- **Cached by `kid` for five minutes**, and an unknown `kid` gets **one** forced
  refresh per cache window — the budget is claimed *before* the fetch, because a
  budget recorded on completion is a budget twenty-five concurrent requests all
  believe is unspent. A failed fetch **keeps the last good set** rather than
  replacing it with an outage.
- `iss`, `aud`, `sub`, `exp`, `iat`, `jti` required. `account_id` is required too,
  but **not by the gem** — see §3 for why that distinction is load-bearing.

One gem: `jwt ~> 3.3`, the first non-observability dependency this service has
taken, for the same reason `stripe` is here. Hand-rolling signature verification
is how `alg: none` and HS256-signed-with-the-public-key get through.

### Authorization, not only authentication

Every `/v1` query is scoped by the token's account, and cross-tenant read and
cross-tenant write are both **404**. `POST /v1/customers` **ignores
`owner_type`/`owner_id` in the body** and `CustomerUpdate` no longer permits
them: the account is a claim and never a parameter. `Idempotency-Key` is now
scoped to the token's `sub` rather than to a constant, so two tenants choosing
the same uuid no longer share one namespace.

A `User`-owned customer is in no account and is therefore **invisible** to `/v1`,
not refused by it — a row with no tenant has nobody to scope it to, and which
account a user belongs to is identity's fact.

### The document

`openapi/v1.yaml` is at **2.0.0**: `security: [{bearerToken: []}]` at the root,
`security: []` on the webhook as a declaration rather than a default, a declared
`bearerToken` scheme, and `Unauthorized` / `CallerIdentityUnavailable` on all
**14** client operations. The "declared, and empty" note is gone — a document that
admits it describes no authorization is a document that describes an open door.
`test/contract/http_surface_contract_test.rb` asserts all of it by name.

### The gem's required-claims list, and why `account_id` is not in it

I moved `account_id` **out** of `TokenVerifier::REQUIRED_CLAIMS`. With it in, the
gem refuses a missing claim with `JWT::MissingRequiredClaim` before
`Principal.build` runs, and that message is actively misleading: the claim is not
missing by accident, `identity` deliberately does not send one. An operator
reading it goes looking for a malformed token instead of for a cross-repository
disagreement they can actually fix. The tenancy claim is now enforced in the one
place that can explain it. The outcome is the same refusal; the diagnosis is the
point.

---

## 3. The cross-repo disagreement, stated rather than worked around

**`identity` does not issue a singular `account_id` on a user token.** It issues
`accounts` — an array of `{account_id, name, slug, role, personal}` on the
`accounts` scope. Its own `internal/oidc/profiles.go` says why:

> a user of a cafaye product is a member of a personal account and usually of
> several team accounts, and a token carrying one of them would be wrong for all
> the others

core's conventions ask for `account_id`, singular. Both sides are self-consistent
and they are not compatible.

**The consequence, stated plainly: until this is decided, a token `identity`
actually issues to a user is refused and `/v1` answers 401.** That is a real
limitation of what shipped and it is not hidden behind a fallback.

The available fixes all cost something, and **the one that costs least in code is
the one that must not be taken**:

- `accounts[0]`, the `personal: true` entry, or "whichever the client meant" —
  **this is the cross-tenant bug billing-12 spent a packet finding.** It produces
  a tenancy key nobody chose, so a user in a personal account and four team
  accounts has every request answered against whichever entry happened to be
  first. A silent cross-tenant read is *worse* than a lockout, because it looks
  like it works.
- `identity` adds a singular `account_id` — but which account is the right one to
  name is the open question, so this cannot be done in `identity` either.
- core rules the claim is an array and every service scopes by "the account this
  request names, verified to be one the caller holds" — which needs a per-request
  account selector, and this service's design forbids the account being a
  parameter.
- **the gateway resolves the account and forwards one `account_id`.** Most likely
  answer, and a fleet decision rather than either repository's.

Recorded as a DECISION NEEDED in `cafaye.yml`, in `README.md`, and in the
`bearerToken` scheme description in the OpenAPI document — **in the document
specifically because an integrator hitting it will read the document and not this
report.** Two tests pin the refusal in the shape `identity` actually issues, and
one of them pins the *single-entry* array, which is the degenerate case that is
easiest to accept by accident: behaviour would then depend on how many accounts a
user happens to belong to, with nothing in the code saying so.

I also changed `cafaye.yml`'s `dependencies` from `[]` to `identity, required:
true`. It was empty because "identity becomes a dependency when billing needs to
ask who a customer is" — that day arrived. `required: true` rather than `false`
because the failure mode without it is a 503 on every `/v1` request: this service
fails closed rather than degrading open, which is the correct direction and still
does not make the dependency soft.

---

## 4. Tests: what they prove, and the two guards that were wrong

`test/authentication/` is two files, **66 runs / 180 assertions**, and it has its
own CI tier with its own count and a **zero-skips** guard — for the reason the
redaction tier has one: a whole-suite green cannot tell "the lock held" from "the
lock was never exercised".

The specs generate a real 2048-bit RSA key and sign real tokens. **Only the fetch
is stubbed**, so a spec cannot pass by arranging a principal: a token with a
broken signature, a wrong `kid` or a past `exp` is refused by the same
`JWT.decode` production uses. And because the accept path is asserted in the same
file, **a verifier that refused everything would fail** — a tier of 66 refusals
and no acceptance is "the door is shut" by another name, not a working API.

**Two of this packet's own guards were wrong on first write, and mutation caught
both. Both are reported because "I broke it on purpose and it noticed" and "I
think it would notice" are different claims, and in both cases the first claim was
false.**

| guard as written | mutation | result |
| --- | --- | --- |
| scan `app/`+`lib/` for `/\bJWT\./` | a file referencing `JWT::JWK` | **not caught** — `JWT::JWK` contains no `JWT.`, so a file doing precisely what the guard forbids passed. Now `/\bJWT\b/`, verified to fire naming file and line |
| `assert_operator account_scoped_queries, :>, 0` | rename `Subscription.for_account` → `for_account_disabled` | **not caught, and it could not have been**: the count's own regex was `scope :for_account`, an unanchored **prefix**, so the rename left the count untouched. Now `assert_equal 4` and the pattern is word-anchored; verified to fail on losing **either** scope |

The second is the more interesting one. That guard is a tripwire **pointing
backwards** — it exists to notice the day scoping disappears — and it was written
so that the disappearance it watches for could not move it. `> 0` asks "is any
scoping left?" when the question worth asking is "is **this** scoping left?".

### The tests that asserted the bug

Four `gap:` characterisation tests in `test/tenant/cross_account_web_test.rb`
pinned the open surface, each coupled to a count of account-constrained queries
that was `0` so they would fail on the day scoping landed. **That day is this
commit and all four fired.** They are rewritten, not deleted: same two accounts,
same requests, each assertion flipped from "the defect reproduces" to "the defect
is refused". The coupling was **kept**, not dropped — the meta test now asserts
`account_scoped_queries == 4`, so the same tripwire points the other way.

`customers_test.rb` **lost three tests and fifteen assertions** because
`bulk_customers` cannot exist: `(owner_type, owner_id, processor)` is unique and
the owner is now the token's account, so an account's listing holds at most one
row. The paging tests moved to `plans_test.rb`, where the catalogue actually
pages. **A suite that only ever grows is a suite in which a deleted assertion is
invisible**, and the CI delta itemisation says so out loud.

The 403 audit in that file **now skips comment lines** — the new code *explains*
the rule in prose containing the word "forbidden", and a scanner whose only remedy
is deleting the explanation is backwards.

---

## 5. Deliberately not done

- **No capability scopes.** `Principal#scope_set` parses the token's `scope` claim
  and nothing reads it. **The consequence is that any authenticated account may
  create, change or delete a plan** — plans are the platform catalogue, the four
  plan routes are authenticated and not account-scoped, and no scope check exists
  because billing has no capability vocabulary in this build's `consumes`. A scope
  string nothing in the fleet grants is a lock that locks everybody out, so this
  is a manager's call (operator-only catalogue, or a write any account may make)
  and it is recorded in `cafaye.yml` and `README.md` rather than invented here.
- **No `tenancy.yml`.** Core ships a fleet checker
  (`harness/tenancy_check.py`) that reads a service's own account-isolation
  declaration, and it reports billing as undeclared:
  `FAIL tenancy.declaration-missing`. billing now has the *material* — 14 routes,
  35 data accesses, negative tests asserting **absence** rather than refusal — but
  not core's *format*, which pins each entry point to a **line number**. A
  hand-maintained line index is the thing core's own checker argues against
  ("a grep reporting darkroom has no routes is worse than no grep"). Written
  deliberately with core's schema in hand, it is a small packet of its own.
  Recorded as a KNOWN GAP with the command and the finding id.
- **The `/v1` prefix is unchanged at 2.0.0.** Core's rule is that a breaking
  change gets a new prefix *beside* the old one so the old contract keeps being
  served — and that is exactly what cannot be done here, because the old `/v1`
  answers every request without a token, so "keep serving `/v1` for compatibility"
  is "keep the vulnerability" and a second prefix over one open door is one open
  door. The major bump plus the reasoning in three places is the signal. A real
  alternative exists and was not taken silently: `/v2` may be served *instead of*
  `/v1` — never both — the moment a gateway knows which prefix a caller is
  entitled to, which this repository cannot arrange for itself.
- **No `guard` integration.** billing verifies the token itself against identity's
  published keys. When the gateway verifies, billing can move to trusting a
  forwarded claim; that is a later decision, and the two answers to "is this
  caller who they say they are" would need reconciling then.
- **No ES256.** `ALGORITHM` is RS256 as a constant. Widening it before identity
  publishes ES256 keys widens the attack surface for nothing.
- **No `retry` on the JWKS fetch.** One forced refresh per window, then
  `Invalid`. An unlimited fetch allowance aimed at identity is worth having
  precisely when the fetch is failing.

---

## 6. Other things worth knowing

- **`CHANGELOG.md` had a stray conflict marker** — a bare `||||||| 80538f5` at line
  24, left by a `diff3` merge in `7251993` (the merge commit for billing-11).
  It was not in either parent. Removed; a file with a conflict marker in it is a
  file nobody can read.
- **`gate.yml`'s lint floor had drifted by eleven.** It said 109; rubocop reported
  **120** inspected on the tree as it stood, so the floor had been eleven below the
  truth through at least one merge — and that file's own argument is that a floor
  too low is a check that has stopped checking, invisibly, because floors never
  block a merge. Raised to the measured **127**. The suite floor moved 998 →
  **1077** in the same commit as `BASELINE_RUNS`, and the CI delta is itemised per
  file in **both directions** so the decrease is on the record.
- The eager-load step compares `$LOADED_FEATURES` against `Dir.glob` at run time,
  so the four new `app/` files needed no change there. A hard-coded 38 would have
  bought a step that goes red when somebody adds a model.
- `bin/rails` and `bin/bundler-audit` fail on this machine with
  `Bundler::GemNotFound` (bundler installs into its own `libexec/gems`); `bundle
  exec` works. Same trap `bin/migrate`'s header documents.

## 7. The checklist, honestly

| | |
| --- | --- |
| `bin/prime` green from a clean worktree | **yes** — exit 0, tree byte-identical |
| new behaviour has a test that fails without it | **yes** — every guard in `test/authentication/` and both rewritten tripwires, and the two mutations above are the evidence |
| lint and security green, nothing disabled | **yes** — rubocop 127 clean, brakeman 0 warnings, bundler-audit no advisories |
| a new gem is named with its cause | **yes** — `jwt`, in `Gemfile`, `AGENTS.md`, `CHANGELOG.md`, `README.md` |
| `openapi/v1.yaml`'s `info.version` raised | **yes** — 2.0.0, with the prefix judgement documented in the version comment |
| every response the code can answer is declared | **yes** — 401 and 503 on all 14 client operations, asserted by name |
| nothing added a 403 | **yes** — `Problem::CATALOG` still has no 403; the catalog is closed and the scan proves no controller reaches past it |
| `AGENTS.md` describes the repository as it now is | **yes** — new **Authorization** section, layout tree, contracts, checklist; and the billing-12/13 paragraphs that said "`/v1` is still unauthenticated" are marked as the state those packets *found* |
| `CHANGELOG.md` has an entry | **yes** — Added, Changed, and the two wrong guards |
