module Webhooks
  # What a normalized processor fact becomes when it leaves this service: the
  # envelope's `type`, `subject` and `data`.
  #
  # A value object so that a handler cannot emit half an event, and so the choice
  # of event type lives with the payload shape that implies it rather than in a
  # table somewhere else that can drift.
  #
  # The `time` is not here. It is the processor's own timestamp rather than a
  # property of the fact, so it travels with the event in `Webhooks::Ingestion`
  # and lands in the outbox row's `time` — a column core owns, and one this
  # service never lets default to the moment it happened to write.
  class Emission
    attr_reader :event_type, :subject, :data

    def initialize(event_type:, subject:, data:)
      @event_type = event_type
      @subject = subject
      @data = data
    end
  end
end
