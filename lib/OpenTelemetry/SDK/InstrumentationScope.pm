use Object::Pad;

package OpenTelemetry::SDK::InstrumentationScope;

our $VERSION = '0.001';

class OpenTelemetry::SDK::InstrumentationScope {
    use OpenTelemetry;

    has $name    :param;
    has $version :param = undef;

    ADJUST {
        $name //= do {
            OpenTelemetry->logger->warnf('Created an instrumentation scope with an undefined name');
            '';
        };
        $version //= '';
    }

    method to_string () { '[' . $name . ':' . $version . ']' }
}
