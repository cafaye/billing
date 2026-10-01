# frozen_string_literal: true

require_relative "telemetry"
require_relative "exporter"

module Kit
  # Installs the tracer provider, or says why it did not.
  #
  # `OpenTelemetry.tracer_provider` is a global, and a global installed twice in
  # one process is a suite asserting about whichever one won. So `install!` returns
  # the provider it built and the caller keeps it.
  module TracerInstaller
    module_function

    # Build the provider, install it globally, and return it. Nil when telemetry
    # is switched off, which is a supported state and not an error.
    def install!(exporter_name:, disabled:, lookup:)
      ok, _reason = Kit::Telemetry.enabled?(exporter_name, disabled)
      return nil unless ok

      exporter = Kit::Exporter.build(exporter_name, lookup)

      # The SIMPLE processor, and the reason is the same as it is in courier and
      # identity: the batch processor exports on a timer, so a test would have to
      # wait for somebody else's interval — which is a sleep, and a sleep is a
      # guess that is wrong on the machine where it matters. `SimpleSpanProcessor`
      # exports on span end, so a span is in the exporter by the time the response
      # has been returned.
      #
      # Its own doc warns against production use, and that warning is real: it
      # exports synchronously on the request thread. That is the deliberate trade
      # in a service whose request volume is a Stripe webhook and a handful of
      # reads — and the OTLP exporter has no retry queue and a short timeout, so a
      # collector that is down costs a failed export rather than a slow request.
      # A service that outgrew it would move to `BatchSpanProcessor` with a
      # bounded queue, and the switch is one line in this file.
      processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)

      # NO `sampler:` KEY, deliberately. The SDK's default is already
      # `Samplers.parent_based(root: Samplers::ALWAYS_ON)` — a root span with no
      # inbound `traceparent` IS sampled — and it still honours
      # `OTEL_TRACES_SAMPLER`, which is what an operator who wants ratio sampling
      # expects. Pinning the sampler here would be defensible and is not done,
      # because pinning it means the next SDK default change is invisible and the
      # failure is a service that exports nothing. Instead the sampler is a
      # TEST: `test/observability/telemetry_test.rb` asks the installed provider
      # whether a root span is sampled, so a default that stops sampling fails a
      # test rather than silently emptying every trace.
      provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
        resource: Kit::Telemetry.resource(lookup)
      )
      provider.add_span_processor(processor)

      OpenTelemetry.tracer_provider = provider

      # THE PROPAGATOR, and installing it is not optional.
      #
      # Without this the SDK uses a no-op propagator, a `traceparent` header is
      # ignored, and every inbound request starts a brand-new trace. The collector
      # then shows one trace per request and nothing per CALLER — which is the
      # whole reason the header is read, and it is a failure that looks like
      # working: spans arrive, they are just all unrelated.
      #
      # `TraceContext` only, and NOT `Baggage`. Baggage propagates caller-chosen
      # key/value pairs into a downstream service's context, this repository has no
      # use for one, and a bag is a channel for a caller to put content into
      # somebody else's process — one more thing to allowlist, for no property
      # anybody asked for. Leaving it out is also what the W3C spec's default
      # baggage limit would then not have to be argued about.
      # `OpenTelemetry.propagation` takes ONE PROPAGATOR, not a list. Assigning an
      # Array reads as though a list were accepted and fails at the first request
      # with `undefined method 'extract' for an instance of Array` — and because
      # this middleware is the OUTERMOST layer of the stack, that is every request
      # this service ever serves. A second propagator (baggage, B3) would be
      # `Context::Propagation::CompositeTextMapPropagator.compose(injectors: […],
      # extractors: […])`; there is one, so the composite is not needed.
      OpenTelemetry.propagation = OpenTelemetry::Trace::Propagation::TraceContext.text_map_propagator

      provider
    end
  end
end
