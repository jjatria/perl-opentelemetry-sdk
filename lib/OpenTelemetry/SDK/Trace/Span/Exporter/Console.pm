use Object::Pad;
# ABSTRACT: An OpenTelemetry span exporter that prints to the console

package OpenTelemetry::SDK::Trace::Span::Exporter::Console;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Trace::Span::Exporter::Console :does(OpenTelemetry::SDK::Trace::Span::Exporter) {
    use Future::AsyncAwait;

    use OpenTelemetry::Constants -trace_export;

    has $stopped;

    async method export (@spans) {
        return TRACE_EXPORT_FAILURE if $stopped;

        require Data::Dumper;
        local $Data::Dumper::Indent   = 0;
        local $Data::Dumper::Terse    = 1;
        local $Data::Dumper::Sortkeys = 1;

        warn Data::Dumper::Dumper($_) . "\n" for @spans;

        TRACE_EXPORT_SUCCESS;
    }

    async method shutdown ( $timeout = undef ) {
        $stopped = 1;
        TRACE_EXPORT_SUCCESS;
    }

    async method force_flush ( $timeout = undef ) { TRACE_EXPORT_SUCCESS }
}
