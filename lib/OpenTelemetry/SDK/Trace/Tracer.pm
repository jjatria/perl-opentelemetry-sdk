use Object::Pad;
# ABSTRACT: A Tracer for the OpenTelemetry SDK

package OpenTelemetry::SDK::Trace::Tracer;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Trace::Tracer :isa(OpenTelemetry::Trace::Tracer) {
    use OpenTelemetry::Constants 'SPAN_KIND_INTERNAL';

    field $name         :param;
    field $version      :param;
    field $span_creator :param;

    method create_span ( %args ) {
        $args{name} //= 'empty';
        $args{kind} //= SPAN_KIND_INTERNAL;

        $args{context} = OpenTelemetry::Context->current
            unless exists $args{context};

        $span_creator->(%args);
    }
}
