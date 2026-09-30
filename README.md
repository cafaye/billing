# billing

`billing` is the cafaye service that owns money: plans, subscriptions, prepaid
credit, usage metering, and webhooks coming in from a payment processor. Every
other cafaye service that charges someone — `parlor` at checkout, `muse` when it
meters a completion — accounts through this one.

**v0 is a scaffold.** There is no billing logic here yet, on purpose: the
scaffolding *is* this packet's deliverable. What exists is the shape every later
packet builds on — two health probes, the money primitive, a database
convention, and an image. What it does today:

```
$ curl -s localhost:3000/healthz
{"status":"ok"}

$ curl -s localhost:3000/readyz
{"status":"ok","checks":{"database":"ok"}}
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

Minitest, no test framework gem. `money.rb` is held to 100% line and branch
coverage, measured with the standard library's `Coverage` so the gate costs
nothing; every row of the table-driven cases in `test/models/money_test.rb` is
part of that gate.

## Layout

```
app/controllers/health_controller.rb   /healthz, /readyz
app/models/money.rb                    the money primitive
db/migrate/…_init.rb                   a no-op; the schema lands in Phase 3
test/                                  minitest, table-driven
cafaye.yml                             the manifest draft — see the DECISION NEEDED note
```

## Conventions

Read `AGENTS.md` before changing anything here. It is the contract: money is
integer minor units, time is UTC, IDs are opaque strings, lockfiles are never
edited as a side effect, and nothing is copied out of `moon/refs/`.

## License

Released under the same license as the rest of cafaye. See `LICENSE` once the
manager adds it — this repository is public and the file is not written yet.
