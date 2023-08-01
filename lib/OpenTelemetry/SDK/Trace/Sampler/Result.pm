use Object::Pad ':experimental(init_expr)';
# ABSTRACT: The result of a sampling decision

package OpenTelemetry::SDK::Trace::Sampler::Result;

our $VERSION = '0.001';

use constant {
    RECORD_AND_SAMPLE => 'RECORD_AND_SAMPLE',
    RECORD_ONLY       => 'RECORD_ONLY',
    DROP              => 'DROP',
};

class OpenTelemetry::SDK::Trace::Sampler::Result {
    field $trace_state :param :reader;
    field $attributes  :param :reader //= {};
    field $decision    :param;

    method sampled () { $decision eq RECORD_AND_SAMPLE }

    method recording () { $decision ne DROP }
}
