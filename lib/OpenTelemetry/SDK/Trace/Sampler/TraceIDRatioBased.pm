use Object::Pad ':experimental(init_expr)';
# ABSTRACT: A sampler based on the trace ID

package OpenTelemetry::SDK::Trace::Sampler::TraceIDRatioBased;

our $VERSION = '0.001';

use OpenTelemetry::SDK::Trace::Sampler::Result;

class OpenTelemetry::SDK::Trace::Sampler::TraceIDRatioBased
    :does(OpenTelemetry::SDK::Trace::Sampler)
{
    use String::CRC32 'crc32';

    field $threshold;
    field $ratio       :param = 1;
    field $description :reader;

    ADJUST {
        $ratio = 0 if $ratio < 0;
        $ratio = 1 if $ratio > 1;

        # Ensure ratio is a floating point number
        # but don't lose precision
        $description = sprintf 'TraceIDRatioBased{%s}',
            $ratio % 1 ? $ratio : sprintf '%.1f', $ratio;

        # This conversion is internal only, just for the placeholder
        # algorithm used below. We convert this to an integer value that
        # can be compared directly with the one derived from the Trace ID,
        # in the range from 0 (never sample) to 2**64 (always sample)
        $threshold = do {
            use bignum;
            ( $ratio * 1 << 64 )->bceil;
        };
    }

    method should_sample (%args) {
        my $trace_state = OpenTelemetry::Trace
            ->span_from_context($args{context})
            ->context->trace_state;

        # TODO: The specific algorithm of this sampler is still being
        # determined. See: https://github.com/open-telemetry/opentelemetry-specification/issues/1413
        # The algorithm implemented below is equivalent to the version
        # used by the Ruby and Go SDKs at the time of writing.

        if ($ratio) {
            my $check = do {
                # We don't care about uninitialised values, since those
                # will just turn into zeroes, which is safe.
                no warnings 'uninitialized';

                # We drop the first 8 bytes and parse the last 8 as an
                # unsigned 64-bit big-endian integer.
                # The dance with N2 instead of Q> is because Q> requires
                # 64-bit integer support on both this specific version of
                # perl (lowercase) and the system that runs it.
                my ( $hi, $lo ) = unpack 'x8 N2', $args{trace_id};
                $hi << 32 | $lo;
            };

            return OpenTelemetry::SDK::Trace::Sampler::Result->new(
                decision    => OpenTelemetry::SDK::Trace::Sampler::Result::RECORD_AND_SAMPLE,
                trace_state => $trace_state,
            ) if $check < $threshold;
        }

        return OpenTelemetry::SDK::Trace::Sampler::Result->new(
            decision    => OpenTelemetry::SDK::Trace::Sampler::Result::DROP,
            trace_state => $trace_state,
        );
    }
}

__END__

=encoding UTF-8

=head1 NAME

OpenTelemetry::SDK::Trace::Sampler::TraceIDRatioBased - A sampler based on the trace ID

=head1 SYNOPSIS

    my $sampler = OpenTelemetry::SDK::Trace::Sampler::TraceIDRatioBased->new(
        ratio => 0.5,
    );

    my $result = $sampler->should_sample( ... );

    if ( $result->sampled ) {
        ...
    }

=head1 DESCRIPTION

This sampler makes a sampling decision based on the span's trace ID, so that
only a certain number of traces are sampled. This number is controlled by a
I<ratio> (which is a number between 0 and 1) provided to
L<the constructor|/new>.

Although the specific algorithm used internally might change in the future,
L<the OpenTelemetry specification|https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/sdk.md#requirements-for-traceidratiobased-sampler-algorithm>
guarantees that however this algorithm is implemented, it will have to fulfill
the following requirements:

=over

=item *

It is deterministic, so that querying a trace ID with a given ratio will
always result in the same sampling decision.

=item *

Any trace ID that would be sampled with a given ratio, must also be sampled
with a ratio that is equal to or greater than the first one.

=back

Note that at the time of writing, the specific algorithm used for this sampler
has
L<not been decided upon|https://github.com/open-telemetry/opentelemetry-specification/issues/1413>
, so differences across languages and implementations might result in a given
trace not being consistently sampled across components of a large system.

The implementation currently used in this module should be consistent with
those of the Ruby and Go SDKs.

=head1 METHODS

This class implements the L<OpenTelemetry::SDK::Trace::Sampler> role.
Please consult that module's documentation for details on the behaviours it
provides.

=head2 new

    $sampler = OpenTelemetry::SDK::Trace::Sampler::TraceIDRatioBased->new(
        ratio => $float // 1,
    )

Constructs a new instance of this sampler. Takes a single optional C<ratio>
named parameter with the ratio to use for the sampling decision. If no ratio
is provided, this ratio will default to 1, meaning that every trace will be
sampled.

This ratio must be a value between 0 and 1. Values outside this range will be
silently clamped to the nearest boundary.

=head2 description

    $string = $sampler->description;

Returns a string starting with C<TraceIDRatioBased> string, with the
configured ratio between braces (C<{...}>).

=head2 should_sample

    $result = $sampler->should_sample(
        context    => $context,
        trace_id   => $trace_id,
        kind       => $span_kind,
        name       => $span_name,
        attributes => \%attributes,
        links      => \@links,
    );

This sampler will make a sampling decision based on the last 7 bytes of the
provided C<trace_id> (the bytes that can be expected to be random).

This method returns a L<OpenTelemetry::SDK::Trace::Sampler::Result> object.
The L<OpenTelemetry::Propagation::TraceContext::TraceState> object for that
result object will be read from the span in the L<OpenTelemetry::Context>
object provided in the C<context> key (or the current context, if none is
provided).

=head1 SEE ALSO

=over

=item L<OpenTelemetry::Context>

=item L<OpenTelemetry::Propagation::TraceContext::TraceState>

=item L<OpenTelemetry::SDK::Trace::Sampler>

=item L<OpenTelemetry::SDK::Trace::Sampler::Result>

=back

=head1 COPYRIGHT AND LICENSE

...
