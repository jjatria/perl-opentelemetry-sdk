#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Trace::Span::Processor::Batch';
use Test2::Tools::Spec;
use Test2::Tools::OpenTelemetry;

use OpenTelemetry::Constants -trace_export;
use Object::Pad;

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

    method reset {
        open my $handle, '>', $path or die $!;
        print $handle '';
    }

    method export      { $self->$log( export      => @_ ); 0 }
    method shutdown    { $self->$log( shutdown    => @_ ); 0 }
    method force_flush { $self->$log( force_flush => @_ ); 0 }
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
    my ( $span, $sampled, @calls, @logs );

    before_case Reset => sub {
        $sampled = 1;
        @logs    = ();
        @calls   = [ 'shutdown' ];

        $span = mock {} => add => [
            snapshot => 'snapshot',
            context  => sub {
                mock {} => add => [
                    trace_flags => sub {
                        mock {} => add => [ sampled => $sampled ];
                    },
                ];
            },
        ];
    };

    case 'Sampled span' => sub {
        @calls = (
            [ export   => [ 'snapshot', 'snapshot' ], 30_000 ],
            [ 'shutdown' ],
        );
    };

    case 'Unsampled span' => sub {
        $sampled = 0;
    };

    case 'Unforeseen errors' => sub {
        my ($mock) = mocked $span;
        $mock->override( context => sub { die 'boom' } );
        @logs = (
            [ error => OpenTelemetry => match qr/unexpected error in .*on_end - boom/ ]
        );
    };

    it Works => { flat => 1 } => sub {
        my $exporter  = Local::Test->new;
        my $processor = CLASS->new(
            batch_size => 2,
            queue_size => 2,
            exporter   => $exporter,
        );

        is messages {
            is $processor->on_end($span), U, 'Returns undefined';
        } => \@logs, 'Logged expected messages';

        is $exporter->calls, [], 'Nothing exported yet';

        is messages {
            is $processor->on_end($span), U, 'Returns undefined';
        } => \@logs, 'Logged expected messages';

        # Make sure we wait before reading the calls
        $processor->shutdown;

        is $exporter->calls, \@calls, 'Correct calls on exporter';
    };
};

tests 'Ignore calls on shutdown' => sub {
    my $processor = CLASS->new( exporter => my $exporter = Local::Test->new );

    $processor->shutdown;
    is $exporter->calls, [ [ 'shutdown' ] ], 'Calling shutdown propagates to exporter';
    $exporter->reset;

    is $processor->on_start(mock, mock), U, 'on_start returns nothing';
    is $processor->on_end(mock),         U, 'on_end returns nothing';

    is $processor->force_flush->get, TRACE_EXPORT_SUCCESS, 'force_flush returns success';
    is $processor->shutdown->get,    TRACE_EXPORT_SUCCESS, 'shutdown returns success';

    is $exporter->calls, [ ], 'No calls got to exporter after shutdown';
};

done_testing;
