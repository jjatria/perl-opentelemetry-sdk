use Object::Pad;
# ABSTRACT: A sampler based on the trace ID

package OpenTelemetry::SDK::Trace::Sampler::TraceIDRatioBased;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Trace::Sampler::TraceIDRatioBased {
    use String::CRC32 'crc32';
    use namespace::clean -except => 'new';

    use OpenTelemetry::SDK::Trace::Sampler::Result;

    has $ratio :param = 1;
    has $description :reader;

    ADJUST {
        # Ensure ratio is a floating point number
        # but don't lose precision
        $description = sprintf 'TraceIDRatioBased{%s}',
            $ratio % 1 ? $ratio : sprintf '%.1f', $ratio;

        # This conversion is internal only, just for the placeholder
        # algorithm used below
        $ratio *= 2**32;
    }

    method should_sample (%args) {
        my $trace_state = OpenTelemetry::Trace
            ->span_from_context($args{context})
            ->context->trace_state;

        # TODO: The specific algorithm of this sampler is still being
        # determined. See: https://github.com/open-telemetry/opentelemetry-specification/issues/1413
        # In the meantime, the requirements of the algorithm are
        # * for it to be deterministic
        # * any trace included by a sample with a ratio X must also
        #   be included by a sampler with a ratio < X
        # This particular implementation is based on the one used by
        # the Toggle CPAN module

        return OpenTelemetry::SDK::Trace::Sampler::Result->new(
            decision    => 'RECORD_AND_SAMPLE',
            trace_state => $trace_state,
        ) if $args{trace_id} && crc32( unpack 'H*', $args{trace_id} ) < $ratio;

        return OpenTelemetry::SDK::Trace::Sampler::Result->new(
            decision    => 'DROP',
            trace_state => $trace_state,
        );
    }
}
