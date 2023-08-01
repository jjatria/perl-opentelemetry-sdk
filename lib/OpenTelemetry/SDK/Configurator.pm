use Object::Pad ':experimental(init_expr)';
# ABSTRACT: Encapsulates the configuration of the OpenTelemetry SDK

package OpenTelemetry::SDK::Configurator;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Configurator {
    use feature 'state';
    use experimental 'try';

    use Module::Runtime 'require_module';

    use OpenTelemetry;
    use OpenTelemetry::Common 'config';
    use OpenTelemetry::Propagator::Composite;
    use OpenTelemetry::SDK::Trace::TracerProvider;

    use namespace::clean -except => 'new';

    field $tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider->new;

    method $configure_propagators {
        state %map = (
            b3           => 'B3',
            b3multi      => 'B3::Multi',
            baggage      => 'Baggage',
            jaeger       => 'Jaeger',
            none         => 'None',
            ottrace      => 'OTTrace',
            tracecontext => 'TraceContext',
            xray         => 'XRay',
        );

        my @names = split ',',
            ( config('PROPAGATORS') // 'tracecontext,baggage' ) =~ s/\s//gr;

        my %seen;
        my @propagators;

        for my $name ( @names ) {
            my $suffix = $map{$name} // do {
                OpenTelemetry->logger->warnf("Unknown propagator '%s' cannot be configured", $name);
                $map{none};
            };

            next if $seen{$suffix}++;

            my $class = 'OpenTelemetry::Propagator::' . $suffix;

            try {
                Module::Runtime::require_module $class;
                push @propagators, $class->new;
            }
            catch ($e) {
                OpenTelemetry->logger->warnf("Error configuring '%s' propagator: %s", $name, $e);
            }
        }

        OpenTelemetry->propagation(
            OpenTelemetry::Propagator::Composite->new(@propagators),
        );
    }

    method $configure_span_processors {
        state %map = (
            jaeger  => 'Jaeger',
            otlp    => 'OTLP',
            zipkin  => 'Zipkin',
            console => 'Console',
        );

        my @names = split ',',
            ( config('TRACES_EXPORTER') // 'otlp' ) =~ s/\s//gr;

        my %seen;
        for my $name ( @names ) {
            next if $name eq 'none';

            unless ( $map{$name} ) {
                OpenTelemetry->logger->warnf("Unknown exporter '%s' cannot be configured", $name);
                next;
            }

            next if $seen{ $map{$name} }++;

            my $exporter  = 'OpenTelemetry::SDK::Trace::Span::Exporter::' . $map{$name};
            my $processor = 'OpenTelemetry::SDK::Trace::Span::Processor::'
                . ( $name eq 'console' ? 'Simple' : 'Batch' );

            try {
                Module::Runtime::require_module $exporter;
                Module::Runtime::require_module $processor;

                $tracer_provider->add_span_processor(
                    $processor->new( exporter => $exporter->new )
                );
            }
            catch ($e) {
                OpenTelemetry->logger->warnf("Error configuring '%s' span processor: %s", $name, $e);
            }
        }
    }

    method configure () {
        # TODO: logger
        # TODO: error_handler

        $self->$configure_propagators;
        $self->$configure_span_processors;
        OpenTelemetry->tracer_provider($tracer_provider);

        return;
    }

}
