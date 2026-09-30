# REPORT-billing-10-gate — declaring billing's gate

**Branch:** `worker/billing-10-gate` · **Base:** `bd6ac84` (`master`, merge of
`worker/billing-06`) · **Not pushed.** The manager pushes after the gate is
green.

**Host:** macOS arm64, 8 cores, **load average 83–107** for the whole of this
run. mise 2026.8.4, ruby 4.0.1 (mise shim), rails 8.1.4, PostgreSQL **18.4**,
rubocop-rails-omakase. One suite at a time throughout; no parallel matrix, no
background stress loop; every network-bound command wrapped in `timeout`.

---

## 1. What this packet did

billing was one of six cafaye services with no `gate.yml`. A developer here
could run `bin/prime`, see green, and learn nothing about whether the gate could
detect anything. This packet declares the gate against `core`'s published format
(`schemas/gate.schema.json`, checked by `harness/gate_check.py`), and shapes
`bin/prime` in the one place it needed shaping.

**Files touched — and only these:**

| File | Change |
|---|---|
| `gate.yml` | new — the declaration |
| `bin/prime` | the toolchain check, and the banner it prints |
| `script/gate_declaration_self_test.sh` | new — the five red proofs, re-runnable |
| `CHANGELOG.md` | one entry at the top of `[Unreleased]` |
| `REPORT-billing-10-gate.md` | this file |

The second worker in this repository (billing-09, on `worker/billing-09-race`)
was not touched, and its worktree
(`billing-worker-billing-08/`) was never written to. `CHANGELOG.md` was appended
at the top of `[Unreleased]` and not reformatted; a conflict there at merge time
is the manager's, as briefed.

---

## 2. The declaration, and the measured numbers behind every line

`gate.command` is `[bin/prime]`, `gate.miseTask` is `prime`,
`gate.entrypoint` is `bin/prime`, `gate.timeoutSeconds` is **1800**.
`gate.proof` has six entries.

### The developer's command and CI's command are the same command

This is a measured claim, not a reading of a job name. `.github/workflows/ci.yml`'s
`gate` job contains a step whose body is literally

```bash
bin/prime 2>&1 | tee "$log" || status=$?
```

so there is no CI-only variant of the gate to drift from, and `ci.invokes` names
`bin/prime` verbatim. `mise.toml`'s `[tasks.prime]` already resolved to
`./bin/prime`, so the one step of the adoption that needed no work needed none.

**What CI adds *around* the same command is the finding**, and it is the
difference §4 is about. A developer running `bin/prime` alone does not get it.

### Every floor, and where it came from

`bin/prime` on this commit, warm, 163s:

```
== ruby 4.0.1 (pinned by .ruby-version)
== bundle install
Bundle complete! 15 Gemfile dependencies, 106 gems now installed.
== rails db:prepare
Created database 'worker_billing_10_gate_development'
Created database 'worker_billing_10_gate_test'
== rubocop
Inspecting 93 files
93 files inspected, no offenses detected
== rails test
Running 763 tests in parallel using 8 processes
763 runs, 2100 assertions, 0 failures, 0 errors, 0 skips
== prime ok (rails Rails 8.1.4)
```

| id | matches | floor | why this floor |
|---|---|---|---|
| `toolchain` | `== ruby 4.0.1 (pinned by .ruby-version)` | — | version-agnostic on purpose; `^== ruby 4\.0\.1` would be a tripwire that dies with the next legitimate bump |
| `bundle` | `== bundle install` | — | a prime that stopped installing is green on a machine that happens to have the gems |
| `database` | `== rails db:prepare` | — | identity's 1430-green-against-an-empty-schema shape, turned inside out |
| `lint` | `([0-9]+) files inspected, no offenses detected` | **93** | structural; the second of two independent numeric floors |
| `suite` | `([0-9]+) runs, … 0 failures, 0 errors, 0 skips` | **763** | the load-bearing proof; `0 skips` is the finding |
| `ok` | `== prime ok (rails Rails 8.1.4)` | — | distinguishes "the suite printed a summary" from "the gate completed" |

**Neither floor has a margin, and that is a decision, not an omission.** The
schema's own guidance is "set it to the number the thing has today: it is then a
decrease-detector, which is the only kind of floor worth having." A margin is a
hole of exactly that size, and billing's first tests to be lost would be the
money arithmetic and the webhook signatures. billing already owns the ratchet
that *moves* the number — `BASELINE_RUNS: '763'`, compared with `!=` and not
`-ge`, in the CI `gate` job — so a soft margin here would only have added a
second, weaker place for it to rot.

**Two numeric floors rather than one, because guard measured what one misses.**
guard's `pass` floor carried a margin of five and stayed **green** through the
deletion of a five-test file; only its `files` floor caught it. `lint` counts
files and `suite` counts runs, they move differently, and a file added to an
existing test file moves only the first. §5 case 2 is that experiment run here.

### The timeout is not a guess

`timeoutSeconds: 1800` is the `timeout-minutes: 30` on this repository's own
`gate` job. A warm gate measured 163s on a host at load 83–107, so the budget is
~11× a warm run, and the cold path is `bundle install` compiling 106 gems
including the `pg` native extension. A hang is now reported at the same
deadline in both places.

---

## 3. `bin/prime`: the toolchain, and the false red it was

The brief's item 2, and it was a live defect, not a hypothetical one.
`bin/prime` did `require ruby`, which asks whether **an** interpreter is on
`PATH`. On any Mac that is satisfied by `/usr/bin/ruby`. Measured, with the
system Ruby first on `PATH` and nothing else changed:

```
== ruby ruby 2.6.10p210 (2022-04-12 revision 67958) [universal.arm64e-darwin25]

== bundle install
/System/Library/…/rubygems.rb:283:in `find_spec_for_exe': Could not find
'bundler' (4.0.18) required by …/Gemfile.lock. (Gem::GemNotFoundException)
```

Exit 1, so it was not a false *green*. It was something arguably worse for the
next person: a red that **names a gem, four steps away from the toolchain that
is wrong**, in which the pin `4.0.1` appears in no line at all. A developer
reads that as a lockfile problem and installs a gem.

`bin/prime` now reads `.ruby-version`, compares it to `RUBY_VERSION`, and refuses
before a gem is touched. Same code as a missing interpreter — **127**, because a
wrong interpreter is a missing interpreter:

```
bin/prime: .ruby-version pins ruby 4.0.1; the ruby on PATH answers '2.6.10'
  run 'mise install' in this worktree, or put mise's shims first on PATH.
  …
```

`.ruby-version` is the same file mise, `ruby/setup-ruby` and the `pins` CI job
read, so there is still exactly one copy of the number. The banner became the
pin rather than `ruby --version`'s whole first line, so the line a proof matches
is an **assertion** rather than a log line — and it is the line that disappears
if the comparison is deleted.

---

## 4. Pass and skip counts, separately, per tier

The brief asks for these separately, and for environment-gated tiers to be named
by variable. Every number below was measured on this commit, not quoted from
`ci.yml`.

| tier | with `core` readable | with `core` unreadable | env-gated by |
|---|---|---|---|
| **whole suite** (`bin/prime`) | **763 runs / 2100 assertions / 0 skips** | **763 runs / 1757 assertions / 20 skips** | `CORE_PATH` (and the `../core` default) |
| **contract** (`test/contract`) | **26 runs / 358 assertions / 0 skips** | **26 runs / 19 assertions / 19 skips** | `CORE_PATH` |
| **rubocop** | 93 files, 0 offenses | 93 files, 0 offenses | not gated |
| **eager load** (`app/**/*.rb` = 38) | CI: on, 38 loaded | **local: `CI` unset → `eager_load` false** | `CI` |

The arithmetic reconciles exactly, which is the check that these are the same
facts seen twice: 20 skips = 19 (envelope contract) + 1 (subscription delivery);
and 2100 − 1757 = **343** = 339 (envelope) + 4 (delivery), matching AGENTS.md's
`+4 assertions, and no new run` for the file that reads core's catalog.

### The finding this packet is really about

**`bin/prime` exits 0 and prints `prime ok` over the "unreadable core" column.**
Same run count, same exit code, **343 assertions of contract checking not
done** — against the frozen v0.2 event schema this service is pinned to. The two
tiers skip rather than fail when they cannot read core, which is *correct* for a
developer with a standalone checkout and *wrong* for a green badge, and
`bin/prime` has no way to tell the two apart.

The declaration closes this by pinning `0 skips` in the `suite` proof: with core
unreadable the summary line no longer matches, so it becomes
`gate.proof-missing`, **a failure**. The declared gate is therefore red on a
machine without a core checkout — which is this repository's own stated
position, not a stricter invention of this packet:

- AGENTS.md: "**locally**, a `19 skipped` in the contract tier … is a missing
  core checkout, **not a pass**."
- The CI `gate` job already "fails the build on a single skipped test".
- `external` carries a `filesystem` requirement naming `CORE_PATH`, with the
  measured symptom quoted as its `unmet`.

### What was deliberately NOT changed, and is the top open item

**`bin/prime` itself still exits 0 over a skipped contract tier.** Making that
nonzero would change what this repository's gate *accepts*, which is a decision
above this packet's remit. So the declaration converts it from silent to named
for anything run through the gate checker, and it does **not** convert it for a
developer who runs `bin/prime` by hand. That asymmetry is the honest limit of
this packet and it is the first thing §7 asks the manager to rule on.

---

## 5. Red-proved five ways, and re-runnable

`script/gate_declaration_self_test.sh` runs all five and asserts the checker goes
red **and names the finding**. 181s, strictly sequential. **5 passed, 0 failed.**
Every breakage was reverted, and a final control re-runs the check so a script
that damages the tree it is testing cannot report success.

| # | breakage | finding(s), as reported |
|---|---|---|
| 0 | *control, unbroken* | exit 0 — run **first**, or five reds prove nothing |
| 1 | `bin/prime` body replaced by `exit 0` | **6 × `gate.proof-missing`** — one per proof |
| 2 | `rm test/integration/health_test.rb` | **`gate.floor` on `lint` (92 vs 93) *and* on `suite` (758 vs 763)** |
| 3 | suite floor raised 763 → 764 | `gate.floor: proof 'suite' reported 763 and the floor is 764` |
| 4 | `rm bin/prime` | `gate.command-missing` + `gate.entrypoint-missing` (static; no suite run) |
| 5 | a `ruby` on `PATH` answering 3.4.2 | `gate.nonzero: the gate exited 127`, plus 6 × `gate.proof-missing` |
| — | *control, after five* | exit 0 — every breakage reverted |

**Case 1 is the one the format exists for**: a declaration entirely true about a
gate that exits 0 without running anything. It is red by six independent
findings, not by the exit code, so it cannot be talked green by editing one away.

**Case 2 is guard's near-miss run forwards.** `health_test.rb` holds **5 tests**,
is referenced by nothing, and touches no money — chosen deliberately so the
100 %-coverage gate cannot be what made the run red, which is what makes the case
show what it was written to show. In guard a 5-test deletion passed the `pass`
floor; here the same-sized deletion is caught twice, by two margin-free floors.

**Case 5 asserts the message, not just the status**, and that is the only reason
it is a test of anything: against the *old* `bin/prime` it would have passed on
the exit code alone, because that also exited nonzero. It asserts exit 127
*and* that the first line names both `4.0.1` and `3.4.2`.

No breakage weakened an assertion, added a sleep, or raised a retry count. Every
one is a deletion, a substitution, a number, or a `PATH`.

---

## 6. The declaration's own result, and the honesty of its limits

```
$ core/harness/bin/gate-check .              → OK: 0 failure(s), 3 warning(s)
$ core/harness/bin/gate-check --prove .      → OK: 0 failure(s), 3 warning(s)  (125s)
```

All six proof lines were confirmed present in the gate's own log — none silently
skipped:

```
== ruby 4.0.1 (pinned by .ruby-version)
== bundle install
== rails db:prepare
93 files inspected, no offenses detected
763 runs, 2100 assertions, 0 failures, 0 errors, 0 skips
== prime ok (rails Rails 8.1.4)
```

The three warnings are all `gate.requirement-unproven`, for the bare-name
`satisfy` commands `mise`, `git` and `bundle`. That severity is **correct** and
is the format's documented tri-state contract: those are claims about *this
machine*, and the checker deliberately does not settle them, because the
alternative is a checker that is red on a laptop and green on CI. The fourth
requirement, `[bin/rails, db:prepare]`, is repository-relative and the checker
**did** verify the file is there — which is why it produced no warning.

**The `database` proof matches a banner and never a connection string.**
`DATABASE_URL` may carry a password, and a pattern containing one is a
credential written into a file that lands in every CI log reporting on it. The
`unmet` text quotes a `PG::ConnectionBad` and a port, not a URL. Nothing in the
six proofs can echo a token, a key or a JWT.

**The suite is hermetic, and that was verified by search rather than believed:**
no `Net::HTTP`, `Faraday`, `open-uri`, `HTTParty`, `RestClient` or `TCPSocket`
anywhere under `app/`, `test/` or `lib/`; the specs drive `FakeStripeAPI`, an
in-process stand-in, and `Processor::StripeClient` refuses to build a request
without `STRIPE_API_KEY`, which the suite never sets. The signing secret is
`StripeWebhookHelpers::WEBHOOK_SECRET` from `test/test_helper.rb` — a credential
for nothing, checked in on purpose.

**The `local`→`CI` seam named in `gate.yml` and not papered over:** the eager
load tier is `config.eager_load = ENV["CI"].present?`. `CI` is unset in a
developer's shell (verified), so the application is **not** eager-loaded locally
and `bin/prime` does not exercise "the application loads" at all. CI sets `CI`
explicitly and asserts both that `eager_load` is true and that `eager_load!`
loaded all 38 `app/**/*.rb`. **Variable: `CI`.**

### `gate.yml` failed its own schema first

Two `external.requirements[].name` fields came in at 459 and 225 characters
against a `maxLength: 200`, and `gate_check.py` answered `gate.schema` naming
both. The prose moved into the surrounding comments, which have no limit. It is
recorded because it is the check working on the file that declares the checks,
and because a reader who copies the shape of the other seven adopters' long
`name` fields will hit the same wall.

---

## 7. Open items for the manager

1. **`bin/prime` still exits 0 over a skipped contract tier.** §4. The
   declaration makes it red through the checker; it does not make it red for a
   developer running the script by hand. Making it nonzero is a change to what
   this repository's gate accepts and is a ruling, not a patch. *My
   recommendation: yes, and in the same commit as a `gate.yml` note — but it is
   the repository's gate and yours to change.*
2. **`bin/prime --fast` does not prepare the database, and its own documentation
   says it does.** Measured: with `DATABASE_URL` pointed at a closed port,
   `bin/prime --fast` runs `bundle install` and **exits 0**, printing
   `== skipping the database, lint and tests (--fast)`. But `--help` says
   "bundle and the database only" and `mise.toml` describes `[tasks.setup]` as
   "Dependencies and database only". So `mise run setup` promises a database and
   delivers none, and a developer who runs it then `bin/rails test` gets a
   connection error. **I did not change it** — it is a documented flag's
   behaviour, not the gate's. It is why `gate.yml`'s database requirement
   declares `[bin/rails, db:prepare]` rather than cafaye-rb's
   `[bin/prime, --fast]`, which would have been a satisfy command that does not
   satisfy.
3. **Raise the floors when billing-09-race merges.** That branch adds two test
   files and four more, so the honest numbers become larger than 763/93. Floors
   never block a merge, so **nothing will go red to say so** — which is why it is
   written here. In the merge commit, or in that branch's own commit: raise
   `minimum` on `suite` and `lint` in `gate.yml`, **and** `BASELINE_RUNS` /
   `BASELINE_ASSERTIONS` in `ci.yml`, together. `CHANGELOG.md` will very likely
   conflict at merge time; that is expected and it is the manager's to resolve.

### Assorted measured facts worth having

- **PostgreSQL major.** Local measurement ran against **18.4** (a Homebrew server
  already on this host); `docker-compose.yml` pins **17** and CI runs **17**.
  Nothing in the suite depends on the major, but a suite green on 18.4 has not
  been shown green on the 17 the image ships. This is a gap in the evidence, not
  a finding.
- **The database name is per checkout** — `worker_billing_10_gate_test` here,
  derived by `config/database.yml` from the directory. No proof matches it, and
  `ci.yml` overrides it with a per-run `DATABASE_URL`.
- **`networking on a cold checkout` was demonstrated, not assumed.** A throwaway
  `Gemfile` requiring an uninstalled gem, with the proxy pointed at a closed
  port, exits **7** with `Could not reach host index.rubygems.org`. A warm gate
  never opened a socket, which is why that requirement says "once, on a cold
  checkout" rather than "network" flatly.
- **A false green I reproduced while measuring this packet,** worth recording
  because it is the fleet's own recorded one: `gate-check … | tail -20; echo
  "EXIT=$?"` printed `EXIT=0` over a checker that had just reported
  `gate.declaration-missing`. `$?` was `tail`'s. Every measurement in this
  report used a log file and the command's own status, and the self-test asserts
  on exit codes taken directly.

---

## 8. Checklist against the brief

| item | done |
|---|---|
| 1. Measure before declaring; record the developer command and CI's | §2 — both are `bin/prime`, read out of the workflow, with the four things CI bolts around it named |
| 2. Toolchain discovery is part of the gate | §3 — the defect reproduced, fixed in `bin/prime`, exit 127 naming both numbers, and case 5 asserts the message |
| 3. `gate.yml` following the seven adopters | §2 — read `guard`, `cafaye-rb` and `core`; shape, argv-not-string, proofs with regex + group + minimum, `external`, `ci` |
| 4. Every floor from a real run | §2 — 763 and 93, both measured; a wrong first guess would have gone red |
| 5. Prove the gate can fail, ≥3 ways | §5 — **five**, each red and naming its finding, all reverted, re-runnable; guard's near-miss addressed head-on with two margin-free floors |
| 6. Pass and skip counts separately; name the env variable | §4 — per tier, both columns, reconciled to the assertion; `CORE_PATH` and `CI` named |
| 7. `CHANGELOG.md` + this report | both |
| Never weaken an assertion | no case weakened one; no sleeps, no raised retries, no loosened thresholds |
| No secrets at rest, logged, or in config | the `database` proof matches a banner by design; the suite is hermetic by search; no `${{ secrets.* }}` added |
| One suite at a time | every run sequential; `--prove` runs 125s, self-test 181s |
| Do not edit `core`; do not push | neither done |
