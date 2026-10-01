# Asserting that a **constraint** refused a write, from inside a test that is
# otherwise transactional.
#
# ## Why this is here and not in each file
#
# `test/models/outbox_processor_event_id_migration_test.rb` was the only test in
# the repository that needed this, and it carried the trick privately. billing-13
# adds two more constraint tests, so the trick was going to exist three times —
# and it is exactly the kind of thing that should exist once, because a copy that
# is subtly wrong produces a test that reports "the index refused" when the
# savepoint, not the index, is what was measured.
#
# ## The problem it solves
#
# A uniqueness violation aborts the enclosing PostgreSQL transaction, after which
# **every** later command on that connection fails with
# `PG::InFailedSqlTransaction`. So a test that wants to assert "the index refuses
# this write" and then carry on has to absorb the violation — a `SAVEPOINT` and a
# `ROLLBACK TO` is the only way, and `ActiveRecord::Transaction#requires_new` is
# how Ruby asks for one.
#
# The violation is caught rather than allowed to propagate, and then the
# transaction is rolled back so the test's own state is unaffected. The exception
# is returned to the caller to assert on, so a test that expected a violation and
# did not get one fails on the assertion rather than passing silently.
module ConstraintRefusals
  # Yields, expecting the database to refuse. Asserts that what it refused with is
  # a `RecordNotUnique` — the class Rails raises for a unique-index violation, and
  # the thing a caller would see as a 409.
  #
  # `expected` narrows it further where a test can say which fact it is asserting,
  # and defaults to the class because "some constraint said no" is usually the
  # whole claim. Pass a block as `message` to name the constraint, which is the
  # version to prefer: a test that says *which* index refused cannot be satisfied
  # by an unrelated one.
  def assert_refused_by_constraint(message = nil, expected: ActiveRecord::RecordNotUnique)
    violation = nil

    ActiveRecord::Base.transaction(requires_new: true) do
      violation = begin
        yield
        nil
      rescue ActiveRecord::StatementInvalid => e
        e
      end
      raise ActiveRecord::Rollback
    end

    assert_instance_of expected, violation,
      message || "expected the database to refuse the write, got #{violation.inspect}"
  end
end

module ActiveSupport
  class TestCase
    include ConstraintRefusals
  end
end
