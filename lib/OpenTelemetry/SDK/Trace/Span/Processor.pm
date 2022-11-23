use Object::Pad;
# ABSTRACT: The abstract interface for OpenTelemetry span processors

package OpenTelemetry::SDK::Trace::Span::Processor;

our $VERSION = '0.001';

role OpenTelemetry::SDK::Trace::Span::Processor {
    method on_start;
    method on_end;

    method shutdown;
    method force_flush;
}
