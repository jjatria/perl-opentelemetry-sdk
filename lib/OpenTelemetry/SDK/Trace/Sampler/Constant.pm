use Object::Pad;
# ABSTRACT: An sampler with a constant result

package OpenTelemetry::SDK::Trace::Sampler::Constant;

our $VERSION = '0.001';

use OpenTelemetry::SDK::Trace::Sampler::Result;

class OpenTelemetry::SDK::Trace::Sampler::Constant {
    use OpenTelemetry::Trace;

    has $decision    :param;
    has $description :param :reader;

    method should_sample (%args) {
        OpenTelemetry::SDK::Trace::Sampler::Result->new(
            decision => $decision,
            trace_state => OpenTelemetry::Trace
                ->span_from_context($args{context})->context->trace_state,
        )
    }
}

use constant {
    ALWAYS_ON => OpenTelemetry::SDK::Trace::Sampler::Constant->new(
        decision    => OpenTelemetry::SDK::Trace::Sampler::Result::RECORD_AND_SAMPLE,
        description => 'AlwaysOnSampler',
    ),
    ALWAYS_OFF => OpenTelemetry::SDK::Trace::Sampler::Constant->new(
        decision    => OpenTelemetry::SDK::Trace::Sampler::Result::DROP,
        description => 'AlwaysOffSampler',
    ),
};
