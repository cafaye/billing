module Processor
  # Base class for everything about talking *out* to a payment processor, so a
  # caller can rescue `Processor::Error` and be sure it caught a processor
  # problem rather than an unrelated bug.
  #
  # The mirror of `Webhooks::Error` on the inbound side. The two namespaces are
  # deliberately separate: what arrives signed from a processor and what we ask
  # of a processor fail for entirely different reasons, and a caller rescuing one
  # never means to catch the other.
  class Error < StandardError; end
end
