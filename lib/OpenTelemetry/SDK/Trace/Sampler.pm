use Object::Pad;
# ABSTRACT: An object that decides whether a span is sampled

package OpenTelemetry::SDK::Trace::Sampler;

our $VERSION = '0.001';

use experimental qw( try signatures );

use Module::Load;
use OpenTelemetry;
use OpenTelemetry::SDK::Trace::Sampler::Constant;

sub ALWAYS_OFF { goto \&OpenTelemetry::SDK::Trace::Sampler::Constant::ALWAYS_OFF }
sub ALWAYS_ON  { goto \&OpenTelemetry::SDK::Trace::Sampler::Constant::ALWAYS_ON  }

sub new ( $, $slug, %args ) {
    try {
        my $class = 'OpenTelemetry::SDK::Trace::Sampler::' . $slug;
        Module::Load::load $class;
        return $class->new(%args);
    }
    catch ($e) {
        OpenTelemetry->logger->warnf('Cannot create %s sampler: %s', $slug, $e);
        return ALWAYS_OFF;
    }
}
