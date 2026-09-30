class ApplicationController < ActionController::API
  # In this order: the trace id first, because every problem body below is built
  # from it, and the error rendering last, because it is the fallback for
  # everything the other two let through.
  include RequestTraceId
  include ProblemResponses
  include CursorPaging
  include IdempotentRequests
end
