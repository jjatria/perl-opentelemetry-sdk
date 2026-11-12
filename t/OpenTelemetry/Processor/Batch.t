#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::Processor::Batch';
use Test2::Tools::Spec;
use Test2::Tools::OpenTelemetry;

use OpenTelemetry::Constants -trace;

use experimental 'signatures';
use Feature::Compat::Try;
use Time::HiRes ();

use lib 't/lib';
use Local::Exporter::Failing;
use Local::Exporter::File;
use Local::Exporter::Gated;

# The monotonic clock the batch processor also uses for its deadlines.
sub mono () { Time::HiRes::clock_gettime( Time::HiRes::CLOCK_MONOTONIC ) }

# Sleeps in a loop until the monotonic clock reaches the given moment.
# A signal can cut a single sleep short here, but never the wait.
sub sleep_until ( $when ) {
    while ( mono() < $when ) {
        try { Time::HiRes::sleep 0.01 } catch ($e) { }
    }
    return;
}

# Wait until the condition holds, or until the timeout in seconds runs
# out. The exports run in another process, so their file lines take a
# moment to arrive.
sub wait_for ( $condition, $name, $timeout = 10 ) {
    my $deadline = Time::HiRes::time + $timeout;
    until ( $condition->() || Time::HiRes::time > $deadline ) {
        try { Time::HiRes::sleep 0.01 } catch ($e) { }
    }
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

    is messages {
        local %ENV = ( %ENV, OTEL_BSP_SCHEDULE_DELAY => -10 );

        CLASS->new( exporter => Local::Exporter::File->new );
    }, [
        [
            warning => 'OpenTelemetry',
            match qr/Schedule delay cannot be negative/,
        ],
    ], 'Warned about a negative schedule delay';
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

tests 'Exports the queue on its own when the schedule delay runs out' => sub {
    my $processor = CLASS->new(
        batch_size     => 4,
        schedule_delay => 100,
        exporter       => my $exporter = Local::Exporter::File->new,
    );

    $processor->process({});

    is $exporter->calls, [], 'Nothing exported before the delay';

    # The export child keeps the queue and the countdown, so nothing in
    # this process has to touch the processor for the due batch to go
    # out: an idle emitting process exports on time.
    wait_for sub { $exporter->calls->@* }, 'The due batch was exported';
    is $exporter->calls, [ [ export => [ {} ], 30_000 ] ],
        'The scheduled export holds the records from the queue';

    $processor->shutdown->get;
};

tests 'The countdown to the next export starts at the previous one' => sub {
    my $processor = CLASS->new(
        batch_size     => 6,
        schedule_delay => 100,
        exporter       => my $exporter = Local::Exporter::File->new,
    );

    # One full batch goes out at once, and one record stays in the queue.
    $processor->process( {}, {}, {}, {}, {}, {}, {} );
    wait_for sub { $exporter->calls->@* == 1 }, 'The full batch was exported';

    # The countdown for the records left behind starts at that export,
    # so these ones do not go out within the delay.
    my $start = mono();
    $processor->process({});
    sleep_until $start + 0.05;
    $processor->process({});
    is $exporter->calls->@*, 1, 'Nothing exported inside the delay';

    # The countdown is due, and the export child notices on its own.
    wait_for sub { $exporter->calls->@* == 2 }, 'The due batch was exported';

    is $exporter->calls, [
        [ export => [ ({}) x 6 ], 30_000 ],
        [ export => [ ({}) x 3 ], 30_000 ],
    ], 'The due batch holds the records from the queue';

    $processor->shutdown->get;
};

tests 'Records after a shutdown are ignored' => sub {
    my $processor = CLASS->new(
        batch_size => 1,
        exporter   => my $exporter = Local::Exporter::File->new,
    );

    $processor->process({});
    wait_for sub { $exporter->calls->@* }, 'The record was exported';

    $processor->shutdown->get;
    $exporter->reset;

    $processor->process({});
    try { Time::HiRes::sleep 0.1 } catch ($e) { }
    is $exporter->calls, [], 'Nothing was exported after the shutdown';

    is $processor->force_flush->get, TRACE_EXPORT_SUCCESS,
        'The flush after the shutdown does nothing';
};

tests 'A flush that times out leaves the rest in the queue' => sub {
    my $processor = CLASS->new(
        batch_size => 2,
        exporter   => my $exporter = Local::Exporter::Gated->new,
    );

    # The first two records make the batch the child is exporting right
    # away, which stays there until the test releases it; the third one
    # waits in the child's queue.
    $processor->process( { id => 1 }, { id => 2 }, { id => 3 } );
    wait_for sub { $exporter->started == 1 }, 'The first export is running';

    # The flush order waits behind the export that is running, and the
    # caller gives up on its acknowledgement after the timeout.
    is $processor->force_flush(0.1)->get, TRACE_EXPORT_TIMEOUT,
        'The flush times out on the export that is running';

    is $exporter->started, 1, 'The child is still on its first export';
    is $exporter->ended,   0, 'and it has exported nothing yet';

    $exporter->release;

    # The child was not killed: it keeps draining the queue the flush
    # asked it to empty, including the record that was still waiting.
    wait_for sub { $exporter->started == 2 },
        'The child exported the record from the queue';
    wait_for sub { $exporter->ended == 2 }, 'and that export ended';

    is $processor->force_flush->get, TRACE_EXPORT_SUCCESS,
        'A later flush finds nothing left to export';

    $processor->shutdown->get;
};

tests 'A flush reports a failed export and flushes the exporter anyway' => sub {
    my $processor = CLASS->new(
        batch_size => 2,
        exporter   => my $exporter = Local::Exporter::Failing->new(
            fail_number => 2,
        ),
    );

    # The first two records go out at once as the child's first export,
    # which succeeds; the last one waits in the child's queue. The
    # flush's drain makes that the child's second export, and it fails;
    # the flush still flushes the exporter and reports the failure.
    $processor->process( {}, {}, {} );

    is $processor->force_flush->get, TRACE_EXPORT_FAILURE,
        'The flush reports the failure';

    # The acknowledgement only arrives after all of this, so the calls
    # are all there already.
    is [ map { $_->[0] } $exporter->calls->@* ],
        [ 'export', 'export', 'force_flush' ],
        'Everything went out before the exporter was flushed';

    $processor->shutdown->get;
};

tests 'A shutdown that cannot wait reports a timeout' => sub {
    my $processor = CLASS->new(
        batch_size => 2,
        exporter   => my $exporter = Local::Exporter::Gated->new,
    );

    # The first two records go to the child at once and stay there
    # until the test releases them; the third one waits in the queue
    # for the drain that the shutdown orders.
    $processor->process( { id => 1 }, { id => 2 }, { id => 3 } );
    wait_for sub { $exporter->started == 1 }, 'The first export is running';

    is $processor->shutdown(0.1)->get, TRACE_EXPORT_TIMEOUT,
        'The shutdown reports the timeout of its flush';

    # A shutdown cannot leave a subprocess behind, so the one still
    # stuck on the gate is killed: the records it held are lost, and
    # neither the drain nor the exporter shutdown happened.
    is $exporter->started, 1,
        'The killed child never took the record from the queue';
    is $exporter->ended, 0, 'The killed child exported nothing';
};

done_testing;
