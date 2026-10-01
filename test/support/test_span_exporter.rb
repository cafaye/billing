# frozen_string_literal: true

require "opentelemetry/sdk"

module TestSupport
  # The exporter the suite installs instead of dialling a collector.
  #
  # It records into memory and returns SUCCESS, and that is the whole of it. Three
  # reasons, and all three are this repository's rules rather than preferences:
  #
  #   1. **Nothing leaves the process.** A test that dialled a collector would be a
  #      socket in a suite whose rule is no network, and a suite that phones an
  #      observability backend is a suite that phones an observability backend.
  #   2. **It is the REAL SDK with an exporter swapped in.** A test therefore reads
  #      `SpanData` — what a collector would actually have received — rather than a
  #      parallel object this repository invented.
  #   3. **The simple processor, not the batch one.** A span is in here by the time
  #      the response has been returned, so no test waits on a timer.
  #
  # THREE CONTRACT MISTAKES HAPPENED HERE WHILE THIS WAS BEING WRITTEN, each of
  # which left the suite GREEN HAVING EXPORTED NOTHING. They are written down here
  # because the next person to touch this class will be near all three:
  #
  #   * the method is `export(span_datas, timeout: nil)` — a `timeout:` KEYWORD.
  #     An `export(span_datas)` is never called, and nothing raises: `SimpleSpanProcessor#on_finish`
  #     rescues everything and hands it to `OpenTelemetry.handle_error`, which logs
  #     and continues. The suite goes green and every span is missing.
  #   * it must answer `export`, `force_flush` AND `shutdown`. That is what
  #     `OpenTelemetry::Common::Utilities.valid_exporter?` checks, and
  #     `SimpleSpanProcessor.new` raises on an exporter that does not — which is
  #     the good case. The bad case is an exporter that passes the check and then
  #     returns something the processor treats as a failure.
  #   * `export` must return `SUCCESS`, not `true`. `SUCCESS` is `0`, and `0` is
  #     TRUTHY in Ruby — so returning `false` is the failure and returning `0` is
  #     the success, which is the opposite of what most languages' conventions
  #     would suggest and exactly the kind of thing a reader gets backwards.
  #   * `SUCCESS` is `OpenTelemetry::SDK::Trace::Export::SUCCESS`, a CONSTANT IN A
  #     SIBLING NAMESPACE, not one this class inherits. Ruby resolves an unqualified
  #     constant through the lexical scope and then the ancestors of the class the
  #     reference appears in — and `Export` is a module `SpanExporter` is NESTED
  #     INSIDE, not one it includes — so a subclass written in `TestSupport` gets
  #     `uninitialized constant` at the moment of export. That raise happens inside
  #     `SimpleSpanProcessor#on_finish`'s rescue, so it is logged and swallowed, and
  #     the suite stays green with nothing recorded. This one really happened.
  #
  # `Kit::Telemetry`'s tests pair every absence assertion with a presence one, and
  # `TestSpans.rendered!` RAISES on an empty export rather than returning "" — so
  # this class cannot silently stop receiving spans.
  class TestSpanExporter < OpenTelemetry::SDK::Trace::Export::SpanExporter
    @spans = []
    @mutex = Mutex.new

    class << self
      # One exporter per PROCESS. `rails test` runs minitest over DRb with one
      # process per worker and a per-worker database, so a process-wide array is
      # already the right unit of isolation: two workers cannot see each other's
      # spans, and a worker that finishes cannot be read by another.
      def instance
        @instance ||= new
      end

      # Every span finished so far, frozen, so a caller cannot edit another test's
      # evidence.
      def finished_spans
        @mutex.synchronize { @spans.dup.freeze }
      end

      # Forget everything. Safe from a `setup` in a test that runs in a worker
      # whose other tests are not running at the same time — which is every
      # minitest test in a DRb worker, because a worker runs its tests one at a
      # time. The observability tests also filter by span NAME, so a test cannot be
      # satisfied by an earlier test's span even when the filter is what matters.
      def clear!
        @mutex.synchronize { @spans.clear }
      end

      def record(span_datas)
        # `concat`, and not `<<`. `export/2` receives the whole batch — the
        # processor hands over an Array even when it holds one element — and
        # appending it as one value puts an Array of SpanData in `@spans`, where
        # every reader then asks it for a `name` and gets NoMethodError. That is
        # a loud failure rather than a silent one, which is the only reason it was
        # worth writing the naive version first.
        @mutex.synchronize { @spans.concat(span_datas.to_a) }
      end
    end

    def export(span_datas, timeout: nil)
      _ = timeout
      return OpenTelemetry::SDK::Trace::Export::FAILURE if @stopped

      self.class.record(span_datas)
      OpenTelemetry::SDK::Trace::Export::SUCCESS
    end
  end
end
