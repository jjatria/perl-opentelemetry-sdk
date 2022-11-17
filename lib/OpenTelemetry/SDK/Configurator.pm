use Object::Pad;

package OpenTelemetry::SDK::Configurator;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Configurator {
    use OpenTelemetry;
    use OpenTelemetry::Context::Propagation::Composite;
    use List::Util 'uniqstr';
    use Module::Runtime 'require_module';
    use feature 'state';
    use experimental 'try';

    method configure ($) {
        # TODO: logger
        # TODO: error_handler

        configure_propagators();
    }

    sub configure_propagators {
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

        my @names = List::Util::uniqstr
            split ',', lc( $ENV{OTEL_PROPAGATORS} || 'tracecontext,baggage' ) =~ s/\s//gr;

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
            OpenTelemetry::Context::Propagation::Composite->new(@propagators),
        );
    }
}
