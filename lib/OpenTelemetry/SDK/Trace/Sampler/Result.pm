use Object::Pad;
# ABSTRACT: The result of a sampling decision

package OpenTelemetry::SDK::Trace::Sampler::Result;

our $VERSION = '0.001';

use constant {
    RECORD_AND_SAMPLE => 'RECORD_AND_SAMPLE',
    RECORD_ONLY       => 'RECORD_ONLY',
    DROP              => 'DROP',
};

class OpenTelemetry::SDK::Trace::Sampler::Result {
    has $trace_state :param :reader;
    has $attributes  :param :reader = undef;
    has $decision    :param;

    ADJUST {
        $attributes //= {};
    }

    method sampled () { $decision eq RECORD_AND_SAMPLE }

    method recording () { $decision ne DROP }
}
