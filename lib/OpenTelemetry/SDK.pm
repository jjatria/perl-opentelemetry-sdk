package OpenTelemetry::SDK;
# ABSTRACT: An implementation of the OpenTelemetry SDK for Perl

our $VERSION = '0.001';

use strict;
use warnings;
use experimental qw( signatures lexical_subs );
use feature 'state';

use Module::Runtime 'require_module';
use Feature::Compat::Try;
use OpenTelemetry::Common 'config';
use OpenTelemetry::Propagator::Composite;
use OpenTelemetry::SDK::Trace::TracerProvider;
use OpenTelemetry;

my sub configure_propagators {
    my $logger = OpenTelemetry->logger;

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

    my ( %seen, @propagators );

    for my $name ( @names ) {
        my $suffix = $map{$name} // do {
            $logger->warnf("Unknown propagator '%s' cannot be configured", $name);
            $map{none};
        };

        next if $seen{$suffix}++;

        my $class = 'OpenTelemetry::Propagator::' . $suffix;

        try {
            Module::Runtime::require_module $class;
            push @propagators, $class->new;
        }
        catch ($e) {
            $logger->warnf("Error configuring '%s' propagator: %s", $name, $e);
        }
    }

    OpenTelemetry->propagation(
        OpenTelemetry::Propagator::Composite->new(@propagators),
    );
}

my sub configure_span_processors {
    my $logger = OpenTelemetry->logger;

    state %map = (
        jaeger  => 'Jaeger',
        otlp    => 'OTLP',
        zipkin  => 'Zipkin',
        console => 'Console',
    );

    my @names = split ',',
        ( config('TRACES_EXPORTER') // 'otlp' ) =~ s/\s//gr;

    my $tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider->new;

    my %seen;
    for my $name ( @names ) {
        next if $name eq 'none';

        unless ( $map{$name} ) {
            $logger->warnf("Unknown exporter '%s' cannot be configured", $name);
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
            $logger->warnf("Error configuring '%s' span processor: %s", $name, $e);
        }
    }

    return $tracer_provider;
}

sub import ( $class ) {
    try {
        # TODO: logger
        # TODO: error_handler

        configure_propagators();

        my $provider = configure_span_processors();
        OpenTelemetry->tracer_provider($provider);
    }
    catch ($e) {
        OpenTelemetry->handle_error(
            exception => $e,
            message   => "Unexpected configuration error: $e"
        );
    }
}

1;
