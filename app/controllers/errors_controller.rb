# Renders the responses Rails raises into.
#
# `config.exceptions_app = routes` points Rails at the four routes below, so a
# 404 for a path that is not part of the api, and a 500 from a bug, are
# `application/problem+json` like every other non-2xx — instead of the HTML page
# Rails would otherwise return, which would be the one response on this service
# a client cannot parse.
#
# There is deliberately no `rescue_from StandardError` here. A 500 that reaches
# this controller has already been logged by Rails with its backtrace; the point
# of this class is to answer the caller with a trace id and nothing else.
class ErrorsController < ActionController::API
  include RequestTraceId
  include ProblemResponses

  # Rails rewrites PATH_INFO to the status code before dispatching here — it
  # keeps the caller's path in `action_dispatch.original_path`. Reporting
  # `instance` as "/404" would be a lie in the one field a support engineer
  # reads, and this class exists precisely so that field is right.
  def not_found
    render_status :not_found
  end

  def unprocessable_entity
    render_status :validation_failed
  end

  def internal_server_error
    render_status :internal
  end

  def service_unavailable
    render_status :unavailable
  end

  private
    def render_status(code)
      problem = Problem.new(
        code: code,
        detail: DETAILS.fetch(code),
        trace_id: trace_id,
        instance: original_path
      )

      render json: problem.to_h, content_type: Problem::MEDIA_TYPE, status: problem.status
    end

    def original_path
      request.get_header("action_dispatch.original_path").presence || request.path
    end

    DETAILS = {
      not_found: "No route matches that path.",
      validation_failed: "The request could not be processed.",
      internal: Problem::INTERNAL_DETAIL,
      unavailable: "This service cannot answer right now."
    }.freeze
end
