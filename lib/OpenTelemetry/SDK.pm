package OpenTelemetry::SDK;
# ABSTRACT: An implementation of the OpenTelemetry SDK for Perl

our $VERSION = '0.023';

use strict;
use warnings;
use experimental qw( signatures lexical_subs );
use feature 'state';

use Module::Runtime;
use Feature::Compat::Try;
use OpenTelemetry::Common 'config';
use OpenTelemetry::Propagator::Composite;
use OpenTelemetry::SDK::Trace::TracerProvider;
use OpenTelemetry::SDK::Logs::LoggerProvider;
use OpenTelemetry;

use Log::Any;
my $logger = Log::Any->get_logger( category => 'OpenTelemetry' );

# TODO: These used to be private methods, but exposing them as part of
# the OpenTelemetry::SDK interface made testing this a lot simpler.
# It might be that exposing them to the user is actually desirable though,
# since it might come in handy for keeping the default configuration
# for _most_ things, but customising it for others. If so, we should
# decide what the interface here will look like.
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

    OpenTelemetry->propagator
        = OpenTelemetry::Propagator::Composite->new(@propagators),
}

sub configure_logger_provider {
    state %map = (
        jaeger  => '::Jaeger',
        otlp    => '::OTLP::Logs',
        zipkin  => '::Zipkin',
        console => 'OpenTelemetry::SDK::Exporter::Console',
    );

    my @names = split ',',
        ( config('LOGS_EXPORTER') // 'otlp' ) =~ s/\s//gr;

    my $provider = OpenTelemetry::SDK::Logs::LoggerProvider->new;

    my %seen;
    for my $name ( @names ) {
        next if $name eq 'none';

        unless ( $map{$name} ) {
            $logger->warnf("Unknown exporter '%s' cannot be configured", $name);
            next;
        }

        next if $seen{ $map{$name} }++;

        my $exporter = $map{$name} =~ /^::/
            ? ( 'OpenTelemetry::Exporter' . $map{$name} )
            : $map{$name};

        my $processor = 'OpenTelemetry::SDK::Logs::LogRecord::Processor::'
            . ( $name eq 'console' ? 'Simple' : 'Batch' );

        try {
            Module::Runtime::require_module $exporter;
            Module::Runtime::require_module $processor;

            $provider->add_log_record_processor(
                $processor->new( exporter => $exporter->new )
            );
        }
        catch ($e) {
            warn "Caught an error: $e";
            $logger->warn(
                'Error configuring log record processor',
                { type => $name, error => "$e" },
            )
        }
    }

    OpenTelemetry->logger_provider = $provider;
}

sub configure_tracer_provider {
    state %map = (
        jaeger  => '::Jaeger',
        otlp    => '::OTLP::Traces',
        zipkin  => '::Zipkin',
        console => 'OpenTelemetry::SDK::Exporter::Console',
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

        my $exporter = $map{$name} =~ /^::/
            ? ( 'OpenTelemetry::Exporter' . $map{$name} )
            : $map{$name};

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

    OpenTelemetry->tracer_provider = $tracer_provider;
}

sub import ( $class ) {
    return if config('SDK_DISABLED');

    try {
        # TODO: error_handler
        configure_propagators();
        configure_logger_provider();
        configure_tracer_provider();
    }
    catch ($e) {
        OpenTelemetry->handle_error(
            exception => $e,
            message   => 'Unexpected configuration error'
        );
    }
}

1;
