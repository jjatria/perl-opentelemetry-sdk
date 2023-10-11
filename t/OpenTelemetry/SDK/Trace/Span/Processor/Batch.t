#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Trace::Span::Processor::Batch';
use Test2::Tools::Spec;
use Test2::Tools::OpenTelemetry;

use Object::Pad;
use Future::AsyncAwait;

class Local::Test :does(OpenTelemetry::Exporter) {
    use File::Temp 'tempfile';
    use JSON::PP;

    use feature 'say';

    field $path;

    ADJUST { ( undef, $path ) = tempfile }

    method $log {
        open my $handle, '>>', $path or die $!;
        say $handle encode_json [ @_ ];
    }

    method calls {
        open my $handle, '<', $path or die $!;

        my @calls;
        while ( my $line = <$handle> ) {
            push @calls, decode_json $line;
        }

        \@calls;
    }

    async method export      { $self->$log( export      => @_ ); 1 }
    async method shutdown    { $self->$log( shutdown    => @_ ); 1 }
    async method force_flush { $self->$log( force_flush => @_ ); 1 }
}

is my $proc = CLASS->new( exporter => Local::Test->new ), object {
    prop isa => $CLASS;
    call [ on_start => mock, mock ], U;
}, 'Can construct processor';

describe Validation => sub {
    tests Exporter => { flat => 1 } => sub {
        like dies { CLASS->new },
            qr/Required parameter 'exporter' is missing/,
            'Exporter is mandatory';

        like dies { CLASS->new( exporter => mock ) },
            qr/Exporter must implement.*: Test2::Tools::Mock/,
            'Exporter is validated';
    };

    tests Environment => sub {
        local %ENV = (
            OTEL_BSP_MAX_EXPORT_BATCH_SIZE => 100,
            OTEL_BSP_MAX_QUEUE_SIZE        =>  50,
        );

        is messages {
            is CLASS->new( exporter => Local::Test->new ),
                object { prop isa => $CLASS },
                'Constructed processor';
        }, [
            [
                warning => 'OpenTelemetry',
                match qr/greater than maximum queue size/,
            ],
        ], 'Logged mismatched environment values';
    };
};

describe on_end => sub {
    my ( $sampled, @calls );

    my $span = mock {} => add => [
        snapshot => 'snapshot',
        context  => sub {
            mock {} => add => [
                trace_flags => sub {
                    mock {} => add => [ sampled => $sampled ];
                },
            ];
        },
    ];

    describe 'Valid cases' => sub {
        case 'Sampled span' => sub {
            $sampled = 1;
            @calls = (
                [ export   => [ 'snapshot', 'snapshot' ], 30_000 ],
                [ shutdown => undef ],
            );
        };

        case 'Unsampled span' => sub {
            $sampled = 0;
            @calls = (
                [ shutdown => undef ],
            );
        };

        it Works => { flat => 1 } => sub {
            local %ENV = (
                OTEL_BSP_MAX_EXPORT_BATCH_SIZE => 2,
                OTEL_BSP_MAX_QUEUE_SIZE        => 2,
            );

            my $exporter  = Local::Test->new;
            my $processor = CLASS->new( exporter => $exporter );

            no_messages {
                is $processor->on_end($span), U, 'Returns undefined';
            };

            is $exporter->calls, [], 'Nothing exported yet';

            no_messages {
                is $processor->on_end($span), U, 'Returns undefined';
            };

            # Make sure we wait before reading the calls
            $processor->shutdown->get;

            is $exporter->calls, \@calls, 'Correct calls on exporter';
        };
    };
};

done_testing;
