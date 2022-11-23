use Object::Pad;
# ABSTRACT: The abstract interface for OpenTelemetry span exporters

package OpenTelemetry::SDK::Trace::Span::Exporter;

our $VERSION = '0.001';

role OpenTelemetry::SDK::Trace::Span::Exporter {
    method export;
    method shutdown;
    method force_flush;
}
