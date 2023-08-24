use Object::Pad ':experimental(init_expr)';
# ABSTRACT: An sampler with that will never sample

package OpenTelemetry::SDK::Trace::Sampler::AlwaysOff;

our $VERSION = '0.001';

use OpenTelemetry::SDK::Trace::Sampler::Result;

class OpenTelemetry::SDK::Trace::Sampler::AlwaysOff
    :does(OpenTelemetry::SDK::Trace::Sampler)
{
    use OpenTelemetry::Trace;

    method description () { 'AlwaysOffSampler' }

    method should_sample (%args) {
        OpenTelemetry::SDK::Trace::Sampler::Result->new(
            decision => OpenTelemetry::SDK::Trace::Sampler::Result::DROP,
            trace_state => OpenTelemetry::Trace
                ->span_from_context($args{context})->context->trace_state,
        )
    }
}

__END__

=encoding UTF-8

=head1 NAME

OpenTelemetry::SDK::Trace::Sampler::AlwaysOff - A sampler that will never sample

=head1 SYNOPSIS

    my $sampler = OpenTelemetry::SDK::Trace::Sampler->new('AlwaysOff');

    my $result = $sampler->should_sample( ... );

    if ( $result->sampled ) {
        # this will never be reached :(
    }

=head1 DESCRIPTION

This module provides a sampler whose
L<should_sample|OpenTelemetry::SDK::Trace::Sampler/should_sample> method
will always return a L<result|OpenTelemetry::SDK::Trace::Sampler::Result> that
is neither sampled nor recording.

=head1 METHODS

This class implements the L<OpenTelemetry::SDK::Trace::Sampler> role.
Please consult that module's documentation for details on the behaviours it
provides.

=head2 new

    $sampler = OpenTelemetry::SDK::Trace::Sampler::AlwaysOff->new;

Returns a new instance of this sampler. Takes no arguments.

=head2 description

    $string = $sampler->description;

Returns the C<AlwaysOffSampler> string.

=head2 should_sample

    $result = $sampler->should_sample(
        context    => $context,
        trace_id   => $trace_id,
        kind       => $span_kind,
        name       => $span_name,
        attributes => \%attributes,
        links      => \@links,
    );

Returns a L<OpenTelemetry::SDK::Trace::Sampler::Result> that is neither
sampled nor recording. The
L<OpenTelemetry::Propagator::TraceContext::TraceState> in the result will be
read from the context provided in the C<context> parameter, or from the
current context if none is provided.

=head1 SEE ALSO

=over

=item L<OpenTelemetry::SDK::Trace::Sampler>

=item L<OpenTelemetry::SDK::Trace::Sampler::Result>

=back

=head1 COPYRIGHT AND LICENSE

...
