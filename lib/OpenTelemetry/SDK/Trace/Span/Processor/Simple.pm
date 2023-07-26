use Object::Pad;
# ABSTRACT: A basic OpenTelemetry span processor

package OpenTelemetry::SDK::Trace::Span::Processor::Simple;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Trace::Span::Processor::Simple :does(OpenTelemetry::SDK::Trace::Span::Processor) {
    use experimental 'try';

    use Future::AsyncAwait;

    use OpenTelemetry::X;
    use OpenTelemetry::Trace 'EXPORT_SUCCESS';

    has $exporter :param;

    ADJUST {
        die OpenTelemetry::X->create(
            Invalid => "Exporter does not support 'export' method: " . ( ref $exporter || $exporter )
        ) unless $exporter->can('export'); # TODO: is there an isa for roles?
    }

    method on_start ( $span, $context ) { EXPORT_SUCCESS }

    method on_end ($span) {
        try {
            return EXPORT_SUCCESS unless $span->context->trace_flags->sampled;
            $exporter->export($span->snapshot);
        }
        catch ($e) {
            OpenTelemetry->handle_error(
                exception => $e,
                message   => sprintf('unexpected error in %s->on_end', ref $self),
            );
        };

        return EXPORT_SUCCESS;
    }

    async method shutdown ( $timeout = undef ) {
        await $exporter->shutdown( $timeout );
    }

    async method force_flush ( $timeout = undef ) {
        await $exporter->force_flush( $timeout );
    }
}

__END__

=encoding UTF-8

=head1 NAME

OpenTelemetry::SDK::Trace::Processor::Simple - A basic OpenTelemetry span processor

=head1 SYNOPSIS

    ...

=head1 DESCRIPTION

This is a simple span processor that receives read-only
L<OpenTelemetry::Trace::Span> instances and forwards them to an exporter as
writable instances of L<OpenTelemetry::SDK::Trace::SpanData>.

This processor will mostly be usedful for testing. It could be suitable for
use in production environments in cases where custom attributes should be
added to spans based on code scopes, etc.

This class I<does> the role defined in
L<OpenTelemetry::SDK::Trace::Span::Processor>. Further details can be found
in the documentation for that module.

=head1 METHODS

=head2 new

    $processor = OpenTelemetry::SDK::Trace::Processor::Simple->new(
        exporter => $span_exporter,
    );

The constructor takes a mandaory C<exporter> parameter that must be set to an
instance of a class that I<does> the L<OpenTelemetry::SDK::Trace::Span::Exporter>
role.

=head2 on_start

    $processor->on_start( $span, $parent_context );

Called when a span is started. In this class, this method does nothing.

=head2 on_end

    $processor->on_end( $span );

Called when a span is ended. Calling this will convert the span into a
writeable instance and forward it to the configured exporter.

=head2 force_flush

    $result = await $processor->force_flush( $timeout );

Calls C<force_flush> on the configured exporter and returns a L<Future> that
will hold the result of that operation.

=head2 shutdown

    $result = await $processor->shutdown( $timeout );

Calls C<shutdown> on the configured exporter and returns a L<Future> that will
hold the result of that operation.

=head1 COPYRIGHT AND LICENSE

...
