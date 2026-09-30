# frozen_string_literal: true

# Webhook ingestion: a processor's event arrives signed, is stored verbatim, is
# processed at most once, and leaves as this service's own events.
#
# The two properties everything here is built around:
#
#   * **A replay is a non-event.** Delivery is at-least-once. Stripe retries on
#     any non-2xx, and a redelivery of the same event id must not produce a
#     second `billing.payment.succeeded` with a second envelope id, because a
#     consumer deduplicating on that id would treat it as new information about
#     money.
#   * **A processor must never be told to retry a decision we already made.**
#     Unknown types, deliberately ignored types and events that failed to process
#     are all recorded and all answered 200. A 5xx here buys nothing — the
#     redelivery hits the same row and the same outcome — and it costs a support
#     conversation every time Stripe gives up.
#
# What comes out the other side is an `OutboxEvent`, the same outbox the domain
# models write to. There is one of them in this repository, and a webhook that
# published by any other route would be the second thing to learn what a
# published event has to carry.
module Webhooks
  # Base class for everything in this namespace, so a caller can rescue
  # `Webhooks::Error` and be sure it caught a webhook problem.
  class Error < StandardError; end

  # A signed, well-formed event that this service deliberately acts on by *not*
  # acting. Raised by a handler, recorded on the row with its reason, and answered
  # 200: the processor has nothing to retry, and "we chose to skip this" has to
  # stay a query rather than an absence.
  #
  # Separate from a failure on purpose. A failure is something to fix; an ignore is
  # a decision, and a future packet that changes its mind should change this one
  # line rather than lose the history of why nothing happened.
  class Ignored < Error
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("ignored: #{reason}")
    end
  end
end
