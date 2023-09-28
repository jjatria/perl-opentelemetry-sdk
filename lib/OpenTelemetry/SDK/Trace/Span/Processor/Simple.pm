use Object::Pad ':experimental(init_expr)';
# ABSTRACT: A basic OpenTelemetry span processor

package OpenTelemetry::SDK::Trace::Span::Processor::Simple;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Trace::Span::Processor::Simple
    :does(OpenTelemetry::Trace::Span::Processor)
{
    use experimental 'try';

    use Future::AsyncAwait;
    use OpenTelemetry::X;

    field $exporter :param;

    ADJUST {
        die OpenTelemetry::X->create(
            Invalid => "Exporter does not support 'export' method: " . ( ref $exporter || $exporter )
        ) unless $exporter->can('export'); # TODO: is there an isa for roles?
    }

    method on_start ( $span, $context ) { }

    method on_end ($span) {
        try {
            return unless $span->context->trace_flags->sampled;
            $exporter->export( [$span->snapshot] )->get;
        }
        catch ($e) {
            OpenTelemetry->handle_error(
                exception => $e,
                message   => sprintf('unexpected error in %s->on_end', ref $self),
            );
        }

        return;
    }

    async method shutdown ( $timeout = undef ) {
        await $exporter->shutdown( $timeout );
    }

    async method force_flush ( $timeout = undef ) {
        await $exporter->force_flush( $timeout );
    }
}
