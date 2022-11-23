use Object::Pad;
# ABSTRACT: An OpenTelemetry span exporter that prints to the console

package OpenTelemetry::SDK::Trace::Span::Exporter::Console;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Trace::Span::Exporter::Console :does(OpenTelemetry::SDK::Trace::Span::Exporter) {
    use Future::AsyncAwait;

    has $stopped;

    async method export (%args) {
        return 0 if $stopped;

        require Data::Dumper;
        local $Data::Dumper::Indent = 0;
        local $Data::Dumper::Terse  = 1;

        Data::Dumper::Dumper($_) for @{ $args{spans} // [] };

        1;
    }

    async method shutdown ( $timeout = undef ) { $stopped = 1 }

    async method force_flush ( $timeout = undef ) { 1 }
}
