#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::Processor::Batch';
use Test2::Tools::Spec;
use Test2::Tools::OpenTelemetry;

use OpenTelemetry::Constants -trace;

use IO::Async::Loop;
use experimental 'signatures';
use File::Temp 'tempfile';
use OpenTelemetry::Exporter;
use Time::HiRes ();

use lib 't/lib';
use Local::Exporter::File;
use Local::Exporter::Gated;

sub run_loop ( $seconds ) {
    IO::Async::Loop->new->delay_future( after => $seconds )->get;
}

# Run the loop until the condition is true, or until the timeout in
# seconds runs out. The default timeout is a generous watchdog.
sub run_loop_until ( $condition, $name, $timeout = 10 ) {
    my $deadline = Time::HiRes::time + $timeout;
    run_loop 0.01 until $condition->() || Time::HiRes::time > $deadline;
    ok $condition->(), $name;
}

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

tests 'Exports on schedule only while the loop runs' => sub {
    my $processor = CLASS->new(
        schedule_delay => 100,
        exporter       => my $exporter = Local::Exporter::File->new,
    );

    $processor->process({}) for 1..3;

    Time::HiRes::sleep 0.3;
    is $exporter->calls, [], 'Nothing exported while the loop does not run';

    run_loop_until sub { $exporter->calls->@* }, 'Exported once the loop ran';

    run_loop 0.3;    # Three more delays with an empty queue

    is $exporter->calls, [
        [ export => [ {}, {}, {} ], 30_000 ],
    ], 'Exported the three records once';

    $processor->shutdown->get;
};

tests 'Waits for the schedule delay' => sub {
    my $processor = CLASS->new(
        schedule_delay => 400,
        exporter       => my $exporter = Local::Exporter::File->new,
    );

    $processor->process({});
    run_loop 0.2;
    is $exporter->calls, [], 'Nothing exported before the delay';

    run_loop_until sub { $exporter->calls->@* }, 'Exported after the delay';

    $processor->shutdown->get;
};

tests 'No scheduled export while another export runs' => sub {
    my $processor = CLASS->new(
        batch_size     => 2,
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    # A full batch starts an export immediately
    $processor->process({}) for 1..2;
    run_loop_until sub { $exporter->started == 1 },
        'The full batch is exporting';

    $processor->process({});
    run_loop 0.3;    # Six delays

    is $exporter->started, 1, 'No second export while the first one runs';

    $exporter->release;
    run_loop_until sub { $exporter->events->@* == 4 }, 'Both exports ended';

    is $exporter->events, [
        [ start => 2 ],
        [ end   => 2 ],
        [ start => 1 ],
        [ end   => 1 ],
    ], 'The scheduled export started after the first export ended';

    $processor->shutdown->get;
};

tests 'No scheduled export until every running export ends' => sub {
    my $processor = CLASS->new(
        batch_size     => 2,
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    # Two full batches export at the same time
    $processor->process( { id => 'A' }, {} );
    $processor->process( { id => 'B' }, {} );
    run_loop_until sub { $exporter->started == 2 },
        'Both full batches are exporting';

    $processor->process({});

    $exporter->release('A');
    run_loop_until sub { grep { $_->[0] eq 'end' } $exporter->events->@* },
        'The first full batch ended';
    run_loop 0.3;    # Six delays

    is $exporter->started, 2,
        'No scheduled export while the second full batch exports';

    $exporter->release;
    run_loop_until sub { $exporter->events->@* == 6 }, 'All exports ended';

    is $exporter->events, [
        [ start => 2 ],
        [ start => 2 ],
        [ end   => 2 ],
        [ end   => 2 ],
        [ start => 1 ],
        [ end   => 1 ],
    ], 'The scheduled export started after both full batches ended';

    $processor->shutdown->get;
};

tests 'Keeps exporting after a failed dispatch' => sub {
    my $processor = CLASS->new(
        batch_size     => 2,
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::File->new,
    );

    # The workers cannot receive a code reference, so dispatching the
    # first batch dies. The third record stays in the queue.
    like warnings {
        $processor->process( { code => sub { } }, {}, { last => 1 } );
    }, [ qr/CODE/ ], 'Warned about the failed dispatch';

    run_loop_until sub { $exporter->calls->@* },
        'The remaining record was exported';

    is $exporter->calls, [
        [ export => [ { last => 1 } ], 30_000 ],
    ], 'Exported the record that was left in the queue';

    $processor->shutdown->get;
};

tests 'Keeps exporting after a failed scheduled dispatch' => sub {
    my $processor = CLASS->new(
        batch_size     => 2,
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::File->new,
    );

    # The first two records make a full batch. The scheduled export of the
    # next two cannot be dispatched, and the last record stays in the queue
    $processor->process( {}, {}, { code => sub { } }, {}, { last => 1 } );

    run_loop_until sub { $exporter->calls->@* == 2 },
        'The remaining record was exported';

    is $exporter->calls, [
        [ export => [ {}, {} ], 30_000 ],
        [ export => [ { last => 1 } ], 30_000 ],
    ], 'Exported the full batch and the record left in the queue';

    $processor->shutdown->get;
};

tests 'Flushing stops at a batch that cannot be dispatched' => sub {
    my $processor = CLASS->new(
        batch_size     => 1,
        schedule_delay => 60_000,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    $exporter->release;

    # A goes out at once. The workers cannot receive the next record, and
    # the last one stays in the queue.
    $processor->process( { id => 'A' }, { code => sub { } }, { id => 'C' } );

    is $processor->force_flush->get, TRACE_EXPORT_FAILURE,
        'force_flush returns a failure';

    run_loop 0.2;
    is $exporter->started, 1, 'force_flush did not export the last record';

    $processor->shutdown->get;
};

tests 'Flushing waits for a running export' => sub {
    my $processor = CLASS->new(
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    $processor->process({});
    run_loop_until sub { $exporter->started == 1 },
        'The scheduled export is running';

    my $flush = $processor->force_flush;
    run_loop 0.2;
    ok !$flush->is_ready, 'force_flush waits';

    $exporter->release;
    is $flush->get, TRACE_EXPORT_SUCCESS, 'force_flush returns success';

    is $exporter->events, [
        [ start => 1 ],
        [ end   => 1 ],
    ], 'The export ended before force_flush returned';

    $processor->shutdown->get;
};

tests 'Flushing waits for every running export' => sub {
    my $processor = CLASS->new(
        batch_size     => 2,
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    $processor->process({ id => 'A' });
    run_loop_until sub { $exporter->started == 1 },
        'The scheduled export is running';

    $processor->process( { id => 'B' }, { id => 'C' } );
    run_loop_until sub { $exporter->started == 2 },
        'The full batch exports while the scheduled export runs';

    my $flush = $processor->force_flush;

    $exporter->release('A');
    run_loop_until sub { grep { $_->[0] eq 'end' } $exporter->events->@* },
        'The scheduled export ended';
    run_loop 0.2;

    ok !$flush->is_ready, 'force_flush waits for the full batch';

    $exporter->release('B');
    is $flush->get, TRACE_EXPORT_SUCCESS, 'force_flush returns success';

    is $exporter->events, [
        [ start => 1 ],
        [ start => 2 ],
        [ end   => 1 ],
        [ end   => 2 ],
    ], 'Both exports ended before force_flush returned';

    $processor->shutdown->get;
};

tests 'Flushing exports the records that were queued before it' => sub {
    my $processor = CLASS->new(
        batch_size     => 2,
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    $processor->process({ id => 'A' });
    run_loop_until sub { $exporter->started == 1 },
        'The scheduled export is running';

    $processor->process({ id => 'B' });
    my $flush = $processor->force_flush;

    # B is no longer in the queue, so this does not make a full batch
    $processor->process({ id => 'C' });

    run_loop_until sub { $exporter->started == 2 },
        'The flush exports B at once';

    $exporter->release('A');
    run_loop_until sub { grep { $_->[0] eq 'end' } $exporter->events->@* },
        'The scheduled export ended';
    run_loop 0.2;

    ok !$flush->is_ready, 'force_flush waits for the export of B';

    $exporter->release('B');
    is $flush->get, TRACE_EXPORT_SUCCESS, 'force_flush returns success';

    is $exporter->events, [
        [ start => 1 ],
        [ start => 1 ],
        [ end   => 1 ],
        [ end   => 1 ],
    ], 'The flush exported B on its own';

    $exporter->release;
    $processor->shutdown->get;
};

tests 'A flush waits for the exports that another flush started' => sub {
    my $processor = CLASS->new(
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    $processor->process({ id => 'A' });
    run_loop_until sub { $exporter->started == 1 },
        'The scheduled export is running';

    $processor->process({ id => 'B' });
    my $first  = $processor->force_flush;
    my $second = $processor->force_flush;

    $exporter->release('A');
    run_loop_until sub { grep { $_->[0] eq 'end' } $exporter->events->@* },
        'The scheduled export ended';
    run_loop 0.2;

    ok !$first->is_ready,  'The first flush waits for the export of B';
    ok !$second->is_ready, 'The second flush waits for it too';

    $exporter->release('B');
    is $first->get,  TRACE_EXPORT_SUCCESS, 'The first flush returns success';
    is $second->get, TRACE_EXPORT_SUCCESS, 'The second flush returns success';
    is $exporter->started, 2, 'B was exported once';

    $processor->shutdown->get;
};

tests 'A flush that times out leaves its exports running' => sub {
    my $processor = CLASS->new(
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    $processor->process({ id => 'A' });
    run_loop_until sub { $exporter->started == 1 },
        'The scheduled export is running';

    $processor->process({ id => 'B' });
    my $first  = $processor->force_flush(0.1);
    my $second = $processor->force_flush;

    is $first->get, TRACE_EXPORT_TIMEOUT, 'The first flush times out';

    $exporter->release('A');
    run_loop_until sub { grep { $_->[0] eq 'end' } $exporter->events->@* },
        'The scheduled export ended';
    run_loop 0.2;

    ok !$second->is_ready, 'The second flush waits for the export of B';

    $exporter->release('B');
    is $second->get, TRACE_EXPORT_SUCCESS, 'The second flush returns success';
    is $exporter->started, 2, 'B was exported once';

    $processor->shutdown->get;
};

tests 'The delay after a flush counts from the end of the flush' => sub {
    my $processor = CLASS->new(
        schedule_delay => 400,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    # This starts the countdown, and the flush exports the record
    $processor->process({});
    my $flush = $processor->force_flush;

    run_loop_until sub { $exporter->started == 1 }, 'The flush is exporting';
    run_loop 0.2;
    $exporter->release;
    is $flush->get, TRACE_EXPORT_SUCCESS, 'force_flush returns success';

    $processor->process({});
    run_loop 0.3;
    is $exporter->started, 1, 'No scheduled export before the delay';

    run_loop_until sub { $exporter->started == 2 }, 'Exported after the delay';

    $processor->shutdown->get;
};

tests 'Flushing times out while an export runs' => sub {
    my $processor = CLASS->new(
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    $processor->process({});
    run_loop_until sub { $exporter->started == 1 },
        'The scheduled export is running';

    is $processor->force_flush(0.1)->get, TRACE_EXPORT_TIMEOUT,
        'force_flush returns a timeout with an empty queue';

    $exporter->release;
    $processor->shutdown->get;
};

tests 'Flushing does not start exports after the timeout' => sub {
    my $processor = CLASS->new(
        exporter => my $exporter = Local::Exporter::Gated->new,
    );

    $processor->process({});

    # No time is left by the time force_flush checks
    is $processor->force_flush(1e-9)->get, TRACE_EXPORT_TIMEOUT,
        'force_flush returns a timeout';

    run_loop 0.2;
    is $exporter->started, 0, 'force_flush did not start an export';

    $exporter->release;
    $processor->shutdown->get;
};

tests 'Flushing waits for exports that take its records' => sub {
    my $processor = CLASS->new(
        batch_size     => 1,
        schedule_delay => 60_000,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    # A goes out at once, and B and C stay in the queue
    $processor->process( { id => 'A' }, { id => 'B' }, { id => 'C' } );
    run_loop_until sub { $exporter->started == 1 }, 'A is exporting';

    my $flush = $processor->force_flush;
    run_loop_until sub { $exporter->started == 2 }, 'The flush exports B';

    # This makes a full batch with C, which was queued before the flush
    $processor->process({ id => 'D' });
    run_loop_until sub { $exporter->started == 3 }, 'A full batch exports C';

    $exporter->release('A');
    $exporter->release('B');
    run_loop_until
        sub { ( grep { $_->[0] eq 'end' } $exporter->events->@* ) == 2 },
        'A and B ended';
    run_loop 0.2;

    ok !$flush->is_ready, 'force_flush waits for the export of C';

    $exporter->release('C');
    is $flush->get, TRACE_EXPORT_SUCCESS, 'force_flush returns success';

    $exporter->release;
    $processor->shutdown->get;
};

tests 'Flushing sees a failed dispatch of its records' => sub {
    my $processor = CLASS->new(
        batch_size     => 2,
        schedule_delay => 60_000,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    # A goes out at once. B stays in the queue, and so does C, which the
    # workers cannot receive.
    $processor->process(
        { id => 'A' }, {},
        { id => 'B' }, {},
        { id => 'C', code => sub { } },
    );
    run_loop_until sub { $exporter->started == 1 }, 'A is exporting';

    my $flush = $processor->force_flush;
    run_loop_until sub { $exporter->started == 2 }, 'The flush exports B';

    # This makes a full batch with C, which was queued before the flush,
    # and dispatching it dies
    like warnings { $processor->process({ id => 'D' }) }, [ qr/CODE/ ],
        'Warned about the failed dispatch';

    $exporter->release;
    is $flush->get, TRACE_EXPORT_FAILURE, 'force_flush returns a failure';

    $processor->shutdown->get;
};

tests 'Flushing stops at a failed export of the queue' => sub {
    my $processor = CLASS->new(
        batch_size     => 2,
        schedule_delay => 60_000,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    $exporter->release;

    # The first two records go out at once, and three stay in the queue.
    # The export of the next batch fails.
    $processor->process(
        { id => 'A' },
        {},
        { id => 'B', result => TRACE_EXPORT_FAILURE },
        {},
        { id => 'C' },
    );

    is $processor->force_flush->get, TRACE_EXPORT_FAILURE,
        'force_flush returns the failure';

    run_loop 0.2;
    is $exporter->started, 2, 'force_flush did not export the last record';

    $processor->shutdown->get;
};

tests 'Flushing stops starting exports when it times out' => sub {
    my $processor = CLASS->new(
        batch_size     => 1,
        schedule_delay => 60_000,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    # One full batch goes out at once, and the rest stays in the queue
    $processor->process( map { { id => $_ } } 1 .. 5 );
    run_loop_until sub { $exporter->started == 1 },
        'The full batch is exporting';

    is $processor->force_flush(0.1)->get, TRACE_EXPORT_TIMEOUT,
        'force_flush returns a timeout';

    run_loop 0.2;
    is $exporter->started, 2, 'force_flush started one export';

    $exporter->release;
    $processor->shutdown->get;
};

tests 'Shutdown waits for exports that wait for a worker' => sub {
    local $ENV{OTEL_PERL_BSP_MAX_WORKERS} = 1;

    my $processor = CLASS->new(
        batch_size     => 1,
        schedule_delay => 60_000,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    # A goes to the only worker. The flush in shutdown starts an export
    # for B, which waits for the worker, and the flush times out.
    $processor->process( { id => 'A' }, { id => 'B' } );
    run_loop_until sub { $exporter->started == 1 },
        'The first export is running';

    my $loop = IO::Async::Loop->new;
    $loop->delay_future( after => 0.3 )
        ->on_done( sub { $exporter->release('A') } )->retain;
    $loop->delay_future( after => 0.6 )
        ->on_done( sub { $exporter->release('B') } )->retain;

    $processor->shutdown(0.1)->get;

    is [ grep { $_->[0] eq 'end' } $exporter->events->@* ],
        [ [ end => 1 ], [ end => 1 ] ],
        'Both exports ended before shutdown returned';
};

tests 'Flushing reports a failed running export' => sub {
    my $processor = CLASS->new(
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    $processor->process({ id => 'A', result => TRACE_EXPORT_FAILURE });
    run_loop_until sub { $exporter->started == 1 },
        'The scheduled export is running';

    # The export of this record succeeds
    $processor->process({ id => 'B' });

    my $flush = $processor->force_flush;
    run_loop_until sub { $exporter->started == 2 }, 'The flush exports B';

    # The failed export ends while the flush still waits for B
    $exporter->release('A');
    run_loop_until sub { grep { $_->[0] eq 'end' } $exporter->events->@* },
        'The scheduled export ended';

    $exporter->release('B');
    is $flush->get, TRACE_EXPORT_FAILURE, 'force_flush returns the failure';

    $processor->shutdown->get;
};

tests 'Flushing reports a failed export that took its records' => sub {
    my $processor = CLASS->new(
        batch_size     => 1,
        schedule_delay => 60_000,
        exporter       => my $exporter = Local::Exporter::Gated->new,
    );

    # A goes out at once, and B and C stay in the queue
    $processor->process(
        { id => 'A' },
        { id => 'B' },
        { id => 'C', result => TRACE_EXPORT_FAILURE },
    );
    run_loop_until sub { $exporter->started == 1 }, 'A is exporting';

    my $flush = $processor->force_flush;
    run_loop_until sub { $exporter->started == 2 }, 'The flush exports B';

    # A full batch takes C, which was queued before the flush. Its export
    # fails, and ends while the flush still waits for B.
    $processor->process({ id => 'D' });
    run_loop_until sub { $exporter->started == 3 }, 'A full batch exports C';

    $exporter->release('C');
    run_loop_until sub { grep { $_->[0] eq 'end' } $exporter->events->@* },
        'The export of C ended';

    $exporter->release('A');
    $exporter->release('B');
    is $flush->get, TRACE_EXPORT_FAILURE, 'force_flush returns the failure';

    $exporter->release;
    $processor->shutdown->get;
};

tests 'Cancelling a flush that waits for an export' => sub {
    # If the future of an async sub or method is cancelled while it waits,
    # after it has reached a defer block that uses one of its variables,
    # perl crashes with a segmentation fault (Future::AsyncAwait 0.71).
    # Cancelling force_flush while it waits for a running export must not
    # do that. Run this in a separate process, so that a crash fails this
    # test instead of ending the test run
    my ( $handle, $script ) = tempfile( SUFFIX => '.pl' );
    print $handle <<'SCRIPT';
use strict;
use warnings;
use IO::Async::Loop;
use OpenTelemetry::Processor::Batch;
use Local::Exporter::Gated;
use Time::HiRes ();

my $exporter  = Local::Exporter::Gated->new;
my $processor = OpenTelemetry::Processor::Batch->new(
    schedule_delay => 50,
    exporter       => $exporter,
);

$processor->process({});

my $deadline = Time::HiRes::time + 10;
IO::Async::Loop->new->delay_future( after => 0.01 )->get
    until $exporter->started || Time::HiRes::time > $deadline;

# The flush starts an export for this record
$processor->process({});

my $flush    = $processor->force_flush;
my $second   = $processor->force_flush;
my $shutdown = $processor->shutdown;
$flush->cancel;

$exporter->release;
print 'second=', $second->get, "\n";
$shutdown->get;
print "exported\n" if $exporter->started == 2;
print "done\n";
SCRIPT
    close $handle;

    open my $pipe, '-|', $^X, '-Ilib', '-It/lib', $script or die $!;
    my $output = do { local $/; <$pipe> };
    close $pipe;

    is $?, 0, 'The process exited normally';
    like $output, qr/^second=0$/m,
        'Cancelling a flush did not stop the exports that it started';
    like $output, qr/^exported$/m, 'The record in the queue was exported';
    like $output, qr/^done$/m, 'The process reached the end';
};

tests 'A flush can wait for another flush in report_result' => sub {
    # Run this in a separate process, so that a deadlock fails this test
    # instead of stopping the test run
    my ( $handle, $script ) = tempfile( SUFFIX => '.pl' );
    print $handle <<'SCRIPT';
use strict;
use warnings;
use Object::Pad;
use OpenTelemetry::Processor::Batch;
use Local::Exporter::File;

class Local::Processor :isa(OpenTelemetry::Processor::Batch) {
    field $nested;

    method report_result ( $result, $count ) {
        print 'nested=', $self->force_flush->get, "\n" unless $nested++;
        return $result;
    }
}

alarm 10;

my $processor = Local::Processor->new(
    exporter => Local::Exporter::File->new,
);

$processor->process({});
print 'outer=', $processor->force_flush->get, "\n";

$processor->shutdown->get;
print "done\n";
SCRIPT
    close $handle;

    open my $pipe, '-|', $^X, '-Ilib', '-It/lib', $script or die $!;
    my $output = do { local $/; <$pipe> };
    close $pipe;

    is $?, 0, 'The process exited normally';
    like $output, qr/^nested=0$/m, 'The flush in report_result returned';
    like $output, qr/^outer=0$/m, 'The outer flush returned';
};

tests 'Shutdown stops the timer' => sub {
    my $processor = CLASS->new(
        schedule_delay => 50,
        exporter       => my $exporter = Local::Exporter::File->new,
    );

    $processor->shutdown->get;
    $exporter->reset;

    $processor->process({});
    run_loop 0.3;

    is $exporter->calls, [], 'No scheduled export after shutdown';
};

tests 'Schedule delay' => sub {
    my $processor;

    is messages {
        $processor = CLASS->new(
            schedule_delay => -1,
            exporter       => my $exporter = Local::Exporter::File->new,
        );

        $processor->process({});
        run_loop 0.5;

        is $exporter->calls, [], 'A negative delay does not export at once';
    }, [
        [
            warning => 'OpenTelemetry',
            match qr/Schedule delay cannot be negative/,
        ],
    ], 'Logged a negative schedule delay';

    $processor->shutdown->get;

    $processor = CLASS->new(
        schedule_delay => 0,
        exporter       => my $exporter = Local::Exporter::File->new,
    );

    $processor->process({});
    # The export runs in a worker, so the test cannot see on which
    # iteration of the loop it started. It can see that the processor did
    # not use the default delay of 5 seconds.
    run_loop_until sub { $exporter->calls->@* },
        'A zero delay does not wait for the default delay', 3;

    $processor->shutdown->get;
};

done_testing;
