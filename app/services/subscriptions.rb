# The subscription domain's own vocabulary: the lifecycle, the state machine and
# the plan-change rule, in one namespace.
#
# Separate from `Webhooks` (what a processor says) and from `Processor` (what we
# ask of one), because neither of those is where a subscription's rules belong.
# The three objects in here are pure Ruby over `Plan` and `Subscription` and know
# nothing about HTTP, about signed payloads or about the processor's wire format —
# which is what lets the state machine be a table and the plan-change rule be a
# comparison.
module Subscriptions
  # Base class for everything here, so a caller can rescue `Subscriptions::Error`
  # and be sure it caught a subscription problem.
  class Error < StandardError; end
end
