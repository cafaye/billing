# A request this service refuses before it reaches a model: a body that is not
# JSON, a cursor it cannot read, a limit that is not a count.
#
# It carries a core problem code, so the one rescue in ProblemResponses can
# render any of them without a class per failure. `field`/`field_code` are set
# only when the failure belongs to a named request field, which is what puts an
# entry in a 422's `errors[]`.
class ParameterError < StandardError
  attr_reader :code, :field, :field_code

  def initialize(code, message, field: nil, field_code: nil)
    @code = code
    @field = field
    @field_code = field_code
    super(message)
  end
end
