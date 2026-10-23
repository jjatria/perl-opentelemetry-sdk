#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::Processor::Batch';
use Test2::Tools::Spec;
use Test2::Tools::OpenTelemetry;

use OpenTelemetry::Constants -trace;

use File::Temp 'tempfile';
use IO::Async::Loop;
use POSIX 'WNOHANG';

use lib 't/lib';
use Local::Exporter::File;

tests Validation => sub {
    like dies { CLASS->new },
        qr/Required parameter 'exporter' is missing/,
        'Exporter is mandatory';

    like dies { CLASS->new( exporter => mock ) },
        qr/Exporter must implement.*: Test2::Tools::Mock/,
        'Exporter is validated';

    is CLASS->new( exporter => Local::Exporter::File->new ), object {
        prop isa => $CLASS;
    }, 'Can construct processor';

    is messages {
        local %ENV = (
            %ENV,
            OTEL_BSP_MAX_EXPORT_BATCH_SIZE => 100,
            OTEL_BSP_MAX_QUEUE_SIZE        =>  50,
        );

        is CLASS->new( exporter => Local::Exporter::File->new ),
            object { prop isa => $CLASS },
            'Constructed processor';
    }, [
        [
            warning => 'OpenTelemetry',
            match qr/greater than maximum queue size/,
        ],
    ], 'Logged mismatched environment values';
};

tests 'Flush queue' => sub {
    my $processor = CLASS->new(
        batch_size => 4,
        queue_size => 4,
        exporter   => Local::Exporter::File->new,
    );

    $processor->process({}) for 1..3;

    no_messages {
        is $processor->force_flush->get, TRACE_EXPORT_SUCCESS,
            'Flushing returns success';
    };

    $processor->shutdown->get;
};

tests 'Shutdown flushes and ignores further calls' => sub {
    my $processor = CLASS->new(
        exporter => my $exporter = Local::Exporter::File->new,
    );

    $processor->shutdown->get;
    is $exporter->calls, [
        [ 'force_flush' ],
        [ 'shutdown' ],
    ], 'Calling shutdown propagates to exporter';

    $exporter->reset;

    is $processor->force_flush->get, TRACE_EXPORT_SUCCESS, 'force_flush returns success';
    is $processor->shutdown->get,    TRACE_EXPORT_SUCCESS, 'shutdown returns success';

    is $exporter->calls, [ ], 'No calls got to exporter after shutdown';
};

tests 'Destroying a processor waits for its workers' => sub {
    my $processor = CLASS->new( exporter => Local::Exporter::File->new );

    # The flush exports the record in a worker
    $processor->process({});
    $processor->force_flush->get;

    local $? = 3 << 8;
    undef $processor;

    is $?, 3 << 8, 'The value of $? did not change';
    is waitpid( -1, WNOHANG ), -1,
        'No worker is left for something else to reap';
};

tests 'Destroying a processor notices a late signal from a worker' => sub {
    # The script holds SIGCHLD until a loop step that waited for a whole
    # second returns. This models a signal that arrives just before the
    # loop starts to wait: perl only runs the handler when the loop wakes
    # up again. The script patches the loop class, so it only works with
    # IO::Async::Loop::Poll. Run it in a separate process, so that the
    # alarm stops it if DESTROY waits forever.
    unless ( IO::Async::Loop->new->isa('IO::Async::Loop::Poll') ) {
        pass 'This test needs IO::Async::Loop::Poll';
        return;
    }

    my ( $handle, $script ) = tempfile( SUFFIX => '.pl' );
    print $handle <<'SCRIPT';
use strict;
use warnings;
use IO::Async::Loop::Poll;
use Local::Exporter::File;
use OpenTelemetry::Processor::Batch;
use POSIX qw( sigprocmask SIG_BLOCK SIG_UNBLOCK SIGCHLD );
use Time::HiRes ();

my $set = POSIX::SigSet->new(SIGCHLD);
{
    no warnings 'redefine';
    my $loop_once = \&IO::Async::Loop::Poll::loop_once;
    *IO::Async::Loop::Poll::loop_once = sub {
        my $start  = Time::HiRes::time;
        my @result = $loop_once->(@_);
        if ( Time::HiRes::time - $start >= 0.9 ) {
            sigprocmask( SIG_UNBLOCK, $set );
            sigprocmask( SIG_BLOCK,   $set );
        }
        return @result;
    };
}

my $processor = OpenTelemetry::Processor::Batch->new(
    exporter => Local::Exporter::File->new,
);

# The flush exports the record in a worker
$processor->process({});
$processor->force_flush->get;

alarm 10;
sigprocmask( SIG_BLOCK, $set );
undef $processor;
print "destroyed\n";
SCRIPT
    close $handle;

    open my $pipe, '-|', $^X, '-Ilib', '-It/lib', $script or die $!;
    my $output = do { local $/; <$pipe> };
    close $pipe;

    is $?, 0, 'The process exited normally';
    like $output, qr/^destroyed$/m, 'DESTROY returned';
};

tests 'Destroying a processor in a forked child does not wait' => sub {
    my $processor = CLASS->new( exporter => Local::Exporter::File->new );

    my $pid = fork // die "Cannot fork: $!";

    unless ( $pid ) {
        # The workers belong to the parent. If the child waits for them,
        # the alarm stops it.
        alarm 10;
        undef $processor;
        POSIX::_exit(0);
    }

    waitpid $pid, 0;
    is $?, 0, 'The child destroyed the processor and exited';
};

tests 'Exits with processors left for global destruction' => sub {
    # Run this in a separate process, because the problem only shows
    # when a process exits. The alarm stops the process if it hangs
    my $code = <<'CODE';
use strict;
use warnings;
use OpenTelemetry;
use OpenTelemetry::SDK::Logs::LoggerProvider;
use OpenTelemetry::SDK::Logs::LogRecord::Processor::Batch;
use OpenTelemetry::SDK::Trace::Span::Processor::Batch;
use OpenTelemetry::SDK::Trace::TracerProvider;
use Local::Exporter::File;

alarm 10;

my $tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider->new;
$tracer_provider->add_span_processor(
    OpenTelemetry::SDK::Trace::Span::Processor::Batch->new(
        exporter => Local::Exporter::File->new,
    ),
);
OpenTelemetry->tracer_provider = $tracer_provider;

my $logger_provider = OpenTelemetry::SDK::Logs::LoggerProvider->new;
$logger_provider->add_log_record_processor(
    OpenTelemetry::SDK::Logs::LogRecord::Processor::Batch->new(
        exporter => Local::Exporter::File->new,
    ),
);
OpenTelemetry->logger_provider = $logger_provider;

print "done\n";
CODE

    open my $pipe, '-|', $^X, '-Ilib', '-It/lib', '-e', $code or die $!;
    my $output = do { local $/; <$pipe> };
    close $pipe;

    is $?, 0, 'The process exited on its own';
    like $output, qr/^done$/m, 'The process reached the end';
};

done_testing;
