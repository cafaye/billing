# frozen_string_literal: true

# Installs the tracer provider, and says on the log whether it did.
#
# An INITIALIZER rather than a line in `config/application.rb`, and the split is
# deliberate: `application.rb` assembles the middleware stack (which needs the
# `Kit::Telemetry` constants to exist) and this file starts the provider they will
# record into. Doing both in `application.rb` would put a network-touching object
# construction in the middle of the class body, where a reader looking for
# "what does this app's middleware look like" would not expect to find it.
#
# ONE LINE, on both paths. Configuration cannot log into the store an operator
# reads, so a service that stopped exporting — because a variable was unset, or
# because the SDK refused something — says so here or says nothing at all, and
# "says nothing at all" is the failure mode this line exists to prevent.
Rails.application.config.after_initialize do
  Kit::Telemetry.log_startup(
    Rails.logger,
    Rails.application.config.x.telemetry.exporter,
    ENV["BILLING_OTEL_DISABLED"].to_s.empty? == false,
    ->(name) { ENV.fetch(name, "") }
  )

  Kit::TracerInstaller.install!(
    exporter_name: Rails.application.config.x.telemetry.exporter,
    disabled: ENV["BILLING_OTEL_DISABLED"].to_s.empty? == false,
    lookup: ->(name) { ENV.fetch(name, "") }
  )
end
