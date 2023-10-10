#!/usr/bin/env perl

use Test2::V0;
use Test2::Tools::Spec;
use Test2::Tools::OpenTelemetry;

use Object::Pad ':experimental(mop)';
use Sentinel;
use OpenTelemetry;
use OpenTelemetry::SDK::Trace::TracerProvider; # For mocking

require OpenTelemetry::SDK;

my $tracer_provider_mock = mock 'OpenTelemetry::SDK::Trace::TracerProvider' => override => [
    new => sub {
        mock {} => track => 1;
    },
];

my ( $propagator, $tracer_provider );
my $mock = mock OpenTelemetry => override => [
    propagator => sub :lvalue {
        sentinel
            get => sub { $propagator },
            set => sub { $propagator = shift };
    },
    tracer_provider => sub :lvalue {
        sentinel
            get => sub { $tracer_provider },
            set => sub { $tracer_provider = shift };
    },
];

after_each Clear => sub { $propagator = $tracer_provider = undef };

it 'Can be disabled' => sub {
    local %ENV = ( OTEL_SDK_DISABLED => 1 );
    OpenTelemetry::SDK->import;
    is $tracer_provider, U, 'Leaves tracer provider unchanged';
};

describe 'Propagators' => sub {
    describe 'Valid input' => sub {
        my ( $env, @keys );

        case None => sub {
            $env  = 'none';
            @keys = ();
        };

        case Baggage => sub {
            $env  = 'baggage';
            @keys = qw( baggage );
        };

        case TraceContext => sub {
            $env  = 'tracecontext';
            @keys = qw( traceparent tracestate );
        };

        case Default => sub {
            $env  = '';
            @keys = qw( traceparent tracestate baggage );
        };

        it 'Works' => sub {
            local %ENV = (
                OTEL_TRACES_EXPORTER => 'console',
                OTEL_PROPAGATORS     => $env,
            );

            no_messages { OpenTelemetry::SDK->import };

            is $propagator, object {
                prop isa => 'OpenTelemetry::Propagator::Composite';
                call_list keys => \@keys;
            }, 'Installed correct propagator';
        };
    };

    tests 'Unknown propagator' => sub {
        local %ENV = (
            OTEL_TRACES_EXPORTER => 'console',
            OTEL_PROPAGATORS     => 'foo',
        );

        is messages { OpenTelemetry::SDK->import }, [
            [ warning => OpenTelemetry => match qr/Unknown propagator 'foo'/ ],
        ], 'Logged unknown propagator';

        is $propagator, object {
            prop isa => 'OpenTelemetry::Propagator::Composite';
            call_list keys => [];
        }, 'Ignored unknown propagator';
    };
};

describe 'Span processors' => sub {
    my ( $env, $processor, $exporter, @keys );

    case Console => sub {
        $env       = 'console';
        $exporter  = 'OpenTelemetry::SDK::Exporter::Console';
        $processor = 'OpenTelemetry::SDK::Trace::Span::Processor::Simple';
    };

    it 'Works' => sub {
        local %ENV = ( OTEL_TRACES_EXPORTER => $env );

        no_messages { OpenTelemetry::SDK->import };

        my ($tracker) = mocked $tracer_provider;

        is $tracker->call_tracking, [
            {
                sub_name => 'add_span_processor',
                sub_ref  => D,
                args     => [
                    D,
                    object {
                        prop isa  => $processor;
                        prop this => validator sub {
                            my $have = Object::Pad::MOP::Class->for_class($processor)
                                ->get_field('$exporter')
                                ->value($_);

                            ref $have eq $exporter;
                        };
                    }
                ],
            }
        ], 'Installed correct exporter and processor';
    };
};

done_testing;
