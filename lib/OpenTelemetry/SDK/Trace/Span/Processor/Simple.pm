use Object::Pad ':experimental(init_expr)';
# ABSTRACT: A basic OpenTelemetry span processor

package OpenTelemetry::SDK::Trace::Span::Processor::Simple;

our $VERSION = '0.025';

class OpenTelemetry::SDK::Trace::Span::Processor::Simple
    :isa(OpenTelemetry::Processor::Simple)
    :does(OpenTelemetry::Trace::Span::Processor)
{
    use Feature::Compat::Try;
    use OpenTelemetry;

    method on_start ( $span, $context ) { }

    method on_end ($span) {
        return unless $span->context->trace_flags->sampled;
        $self->process( $span->snapshot );
    }
}
