# The corpus that drives the money paths under `Coverage`.
#
# Loaded by the probe process (see `MoneyCoverage`), which is the only place it
# needs to exist: every case here is also asserted for behaviour in
# `test/models/money_test.rb` and
# `test/services/subscriptions/plan_change_test.rb`. The point of keeping it in
# one file is that a case added to cover a new branch is a case those files run,
# and there is no second list of cases to forget.
#
# Every branch in `Money` and `PlanChange` is reached from here, including the
# refusals. A corpus of only successful calls would leave the error arms
# unmeasured, and the gate would be measuring the wrong thing — which is exactly
# what the gate's own honesty test in
# test/coverage/money_paths_coverage_test.rb checks by feeding it a corpus that
# reaches almost nothing and requiring it to report that.
#
# `attempt` is not decoration. `Money` raises on a Float and on a cross-currency
# addition, and those raises are the arms being measured; an unrescued one would
# take the probe process down before it could write a report, and the gate would
# fail with "no report" rather than with the coverage it is supposed to be
# reporting. The line is recorded as executed either way, which is why rescuing
# here measures the branch rather than hiding it.
module MoneyCoverageExercise
  module_function

  # Runs the block and reports what it raised, so a refusal is an outcome rather
  # than a crash.
  def attempt
    { raised: nil, value: yield }
  rescue StandardError => e
    { raised: e }
  end

  def plans
    @plans ||= { monthly: {}, yearly: {}, other: {}, unpriced: {}, jpy: {}, kwd: {} }
  end

  def plan(kind, minor, price_id, currency: "USD", interval: "month")
    plans.fetch(kind)[[ minor, price_id ]] ||= Plan.new(
      name: "#{kind} #{minor} #{price_id}",
      slug: "#{kind}-#{minor}-#{price_id}",
      price: Money.new(minor, currency),
      interval: interval,
      processor_price_id: price_id
    )
  end

  def change(from, to)
    attempt { Subscriptions::PlanChange.new(from: from, to: to) }
  end

  # Every method of the change, called, with the refusals caught. Each call goes
  # through `attempt`, because a refusal is an arm being measured rather than a
  # failure of the measurement.
  def exercise_change(subject)
    [ attempt { subject.timing }, attempt { subject.upgrade? }, attempt { subject.downgrade? },
      attempt { subject.proration_behavior }, attempt { subject.to_price_id } ]
  end

  # The corpus the gate measures. Every branch in `Money` and `PlanChange`, with
  # the refusals included.
  def full
    call
  end

  # A corpus that reaches almost none of it. The gate must report this as
  # uncovered rather than as a pass — see the honesty test in
  # test/coverage/money_paths_coverage_test.rb, which is the only thing stopping
  # a gate that measures nothing from passing vacuously.
  def minimal
    Money.zero("USD")
  end

  def call
    # --- Money: construction ----------------------------------------------------
    Money.new(1900, "USD")
    Money.new(1900, "usd")
    Money.new(1900, :usd)
    Money.new(0, "JPY")
    Money.new(1, "KWD")
    Money.new(1, "CLF")
    Money.new(Money::MAX_MINOR_UNITS, "USD")
    Money.new(Money::MIN_MINOR_UNITS, "USD")
    attempt { Money.new(10.5, "USD") }
    attempt { Money.new(nil, "USD") }
    attempt { Money.new(100, "US") }
    attempt { Money.new(100, nil) }
    attempt { Money.new(100, 840) }
    attempt { Money.new(Money::MAX_MINOR_UNITS + 1, "USD") }
    attempt { Money.new(Money::MIN_MINOR_UNITS - 1, "USD") }

    # --- Money: from_major ------------------------------------------------------
    Money.from_major("10.50", "USD")
    Money.from_major(10, "USD")
    Money.from_major(BigDecimal("0.01"), "USD")
    Money.from_major("1000", "JPY")
    Money.from_major("1.234", "KWD")
    Money.from_major("1.2345", "CLF")
    attempt { Money.from_major("10.505", "USD") }
    attempt { Money.from_major("10.5", "JPY") }
    attempt { Money.from_major("1.2345", "KWD") }
    attempt { Money.from_major("10.5", "USD") }
    attempt { Money.from_major("92233720368547758.08", "USD") }
    attempt { Money.from_major("10.00", "nope") }
    attempt { Money.from_major(1..2, "USD") }
    attempt { Money.from_major(BigDecimal("NaN"), "USD") }
    attempt { Money.from_major("abc", "USD") }
    Money.zero("jpy")

    # --- Money: arithmetic ------------------------------------------------------
    Money.new(1050, "USD") + Money.new(250, "USD")
    Money.new(1050, "USD") - Money.new(50, "USD")
    Money.new(1000, "USD") - Money.new(250, "USD")
    Money.new(1050, "USD") * 3
    Money.new(1050, "USD") * 0
    Money.new(1050, "USD") * -2
    -Money.new(1050, "USD")
    Money.new(-1050, "USD").abs
    Money.new(1050, "USD").abs
    attempt { Money.new(Money::MAX_MINOR_UNITS, "USD") + Money.new(1, "USD") }
    attempt { Money.new(100, "USD") + Money.new(100, "EUR") }
    attempt { Money.new(100, "USD") + 100 }
    attempt { Money.new(100, "USD") - Money.new(100, "EUR") }
    attempt { Money.new(100, "USD") - Money.new(250, "USD") }
    attempt { Money.new(1050, "USD") * 1.5 }
    attempt { Money.new(1050, "USD") * Money.new(2, "USD") }
    attempt { Money.new(1050, "USD") * 2 }

    # --- Money: predicates and comparison ---------------------------------------
    Money.new(0, "USD").zero?
    Money.new(0, "USD").zero?("usd")
    Money.new(0, "USD").zero?("EUR")
    Money.new(1, "USD").zero?("USD")
    attempt { Money.new(0, "USD").zero?("nope") }
    Money.new(1, "USD").positive?
    Money.new(-1, "USD").negative?
    Money.new(100, "USD") <=> Money.new(100, "USD")
    Money.new(100, "USD") == Money.new(200, "USD")
    Money.new(100, "USD") == Money.new(100, "EUR")
    Money.new(100, "USD") == 100
    Money.new(100, "USD").hash
    Money.new(100, "USD").eql?(Money.new(100, "EUR"))
    Money.new(100, "USD") <=> 100
    begin
      Money.new(100, "USD") < Money.new(200, "EUR")
    rescue ArgumentError
      nil
    end

    # --- Money: rendering -------------------------------------------------------
    Money.new(1050, "USD").to_s
    Money.new(100, "USD").to_s
    Money.new(5, "USD").to_s
    Money.new(0, "USD").to_s
    Money.new(-2550, "USD").to_s
    Money.new(1000, "JPY").to_s
    Money.new(1234, "KWD").to_s
    Money.new(12_345, "CLF").to_s
    Money.new(1050, "USD").to_h
    Money.new(1050, "USD").to_major
    Money.new(-1234, "KWD").to_major
    Money.new(1000, "JPY").to_major
    Money.new(1, "USD").exponent

    # --- PlanChange: every arm of the one comparison ----------------------------
    # Both directions, the boundary (equal), the free cases, both refusals from
    # each of the three questions, and the one destination with no processor
    # price.
    exercise_change change(plan(:monthly, 1900, "a"), plan(:monthly, 1900, "b"))[:value]
    exercise_change change(plan(:monthly, 1900, "a"), plan(:monthly, 1901, "b"))[:value]
    exercise_change change(plan(:monthly, 1900, "a"), plan(:monthly, 1899, "b"))[:value]
    exercise_change change(plan(:monthly, 0, "a"), plan(:monthly, 100, "b"))[:value]
    exercise_change change(plan(:monthly, 100, "a"), plan(:monthly, 0, "b"))[:value]
    exercise_change change(plan(:monthly, 1900, "a"), plan(:other, 1900, "b", currency: "EUR"))[:value]
    exercise_change change(plan(:monthly, 1900, "a"), plan(:yearly, 19_000, "b", interval: "year"))[:value]
    exercise_change change(plan(:monthly, 1900, "a"), plan(:unpriced, 2900, "b"))[:value]
    exercise_change change(plan(:jpy, 1000, "a"), plan(:jpy, 2000, "b"))[:value]
    exercise_change change(plan(:kwd, 1000, "a"), plan(:kwd, 999, "b"))[:value]
  end
end
