use Object::Pad ':experimental(init_expr)';

package OpenTelemetry::SDK::InstrumentationScope;

our $VERSION = '0.001';

class OpenTelemetry::SDK::InstrumentationScope {
    use OpenTelemetry;

    field $name       :param :reader;
    field $version    :param :reader //= '';
    field $attributes :param :reader //= {};

    ADJUST {
        $name //= do {
            OpenTelemetry->logger->warnf('Created an instrumentation scope with an undefined name');
            '';
        };
    }

    method to_string () { '[' . $name . ':' . $version . ']' }
}
