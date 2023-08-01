use Object::Pad ':experimental(init_expr)';
# ABSTRACT: A composite sampler that delegates to parents

package OpenTelemetry::SDK::Trace::Sampler::ParentBased;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Trace::Sampler::ParentBased {
    use OpenTelemetry::SDK::Trace::Sampler::Constant;

    field $root                      :param;
    field $remote_parent_sampled     :param //= OpenTelemetry::SDK::Trace::Sampler::Constant::ALWAYS_ON;
    field $remote_parent_not_sampled :param //= OpenTelemetry::SDK::Trace::Sampler::Constant::ALWAYS_OFF;
    field $local_parent_sampled      :param //= OpenTelemetry::SDK::Trace::Sampler::Constant::ALWAYS_ON;
    field $local_parent_not_sampled  :param //= OpenTelemetry::SDK::Trace::Sampler::Constant::ALWAYS_OFF;

    method description () {
        sprintf 'ParentBased{'
        . 'root=%s,'
        . 'remote_parent_sampled=%s,'
        . 'remote_parent_not_sampled=%s,'
        . 'local_parent_sampled=%s,'
        . 'local_parent_not_sampled=%s}',
            map $_->description,
                $root,
                $remote_parent_sampled,
                $remote_parent_not_sampled,
                $local_parent_sampled,
                $local_parent_not_sampled;
    }

    method should_sample (%args) {
        my $span_context = OpenTelemetry::Trace->span_from_context($args{context})->context;
        my $trace_flags  = $span_context->trace_flags;

        my $delegate = $span_context->valid
            ? $root
            : $span_context->remote
                ? $trace_flags->sampled
                    ? $remote_parent_sampled
                    : $remote_parent_not_sampled
                : $trace_flags->sampled
                    ? $local_parent_sampled
                    : $local_parent_not_sampled;

        $delegate->should_sample(%args);
    }
}
