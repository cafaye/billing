# frozen_string_literal: true

module TestSupport
  # Reading the spans `TestSpanExporter` recorded, and the one guard that keeps a
  # suite which exported nothing from passing quietly.
  module TestSpans
    module_function

    # Every recorded span whose name is `name`, in the order they finished.
    def finished_spans(name: nil)
      spans = TestSpanExporter.finished_spans
      return spans if name.nil?

      spans.select { |span| span.name == name }
    end

    # The REQUEST spans, which is what every observability test here is about.
    def request_spans
      finished_spans(name: Kit::Telemetry::REQUEST_SPAN_NAME)
    end

    # `rendered!/0` and not `rendered/0`, and the raise is the whole point.
    #
    # A redaction test asserts the ABSENCE of a string from everything billing
    # exported. A boundary that exports nothing satisfies that assertion
    # completely, in about a millisecond, having proved nothing at all — and that
    # is not hypothetical: three separate bugs did exactly this while this
    # repository's telemetry was being written (see `TestSpanExporter`). So the
    # one function every canary test reads RAISES when the export is empty, and
    # every absence assertion is therefore also a presence one.
    def rendered!(name: Kit::Telemetry::REQUEST_SPAN_NAME)
      spans = finished_spans(name: name)
      if spans.empty?
        raise "no span named #{name.inspect} was exported. " \
              "An absence assertion over an empty export proves nothing: this is the " \
              "failure mode three exporter-contract bugs produced, and refusing to " \
              "answer here is what makes it a red rather than a green."
      end

      spans.map { |span| render(span) }.join("\n")
    end

    # One span as a single readable line, attributes sorted so a diff is a diff.
    #
    # Sorted because `SpanData#attributes` is a Hash built in insertion order and
    # two runs can insert in a different order — a test that compares two rendered
    # exports would be comparing two orderings of the same facts.
    def render(span)
      pairs = span.attributes.sort_by { |key, _value| key.to_s }
                    .map { |key, value| "#{key}=#{value.inspect}" }
                    .join(" ")
      status = span.status.ok? ? "unset" : span.status.code.to_s.downcase
      "name=#{span.name} kind=#{span.kind} status=#{status} #{pairs}"
    end

    # Every value in the span, as strings, for a `refute_includes`.
    def attribute_values(name: Kit::Telemetry::REQUEST_SPAN_NAME)
      finished_spans(name: name).flat_map { |span| span.attributes.map { |_key, value| value.to_s } }
    end
  end
end
