use Object::Pad;

package OpenTelemetry::SDK::Trace::Sampler;
# ABSTRACT: The abstract interface for a sampler object

our $VERSION = '0.026';

role OpenTelemetry::SDK::Trace::Sampler {
    method description;
    method should_sample;
}
