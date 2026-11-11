#!/usr/bin/env perl

use Test2::V0;

use Object::Pad;
use Time::HiRes qw( sleep time );

use OpenTelemetry::Exporter;
use OpenTelemetry::Processor::Batch;

# An exporter that records, per call, which process ran it: the test uses
# that to find the processor's export child and kill it.
class Local::Exporter::PidFile :does(OpenTelemetry::Exporter) {
    use File::Temp 'tempfile';
    use Future::AsyncAwait;
    use JSON::PP;

    use feature 'say';

    field $path;
    field $done;

    ADJUST { ( undef, $path ) = tempfile }

    method _log {
        open my $handle, '>>', $path or die $!;
        say $handle encode_json [ @_ ];
        return 0;
    }

    method calls {
        open my $handle, '<', $path or die $!;
        return [ map { decode_json $_ } grep { /\S/ } <$handle> ];
    }

    method export {
        my ( $items ) = @_;
        $self->_log( 'export', $$, scalar $items->@* );
        return 0;
    }

    async method force_flush {
        return 0 if $done;
        $self->_log( 'force_flush', $$ );
        return 0;
    }

    async method shutdown {
        return 0 if $done;
        $done = 1;
        $self->_log( 'shutdown', $$ );
        return 0;
    }
}

# A processor that remembers its drop reports, which is how a batch lost
# to an unusable export child is surfaced now that no batch is ever
# exported inline as a fallback.
class Local::BatchProbe :isa(OpenTelemetry::Processor::Batch) {
    field @dropped;

    method report_dropped ( $reason, $count ) {
        push @dropped, [ "$reason", 0 + $count ];
        return $self;
    }

    method dropped { \@dropped }
}

my $exporter  = Local::Exporter::PidFile->new;
my $processor = Local::BatchProbe->new(
    batch_size => 3,
    exporter   => $exporter,
);

my $exports = sub {
    return [ grep { $_->[0] eq 'export' } $exporter->calls->@* ];
};

my $wait_for_exports = sub {
    my ( $want ) = @_;
    my $deadline = time + 10;
    while ( time < $deadline ) {
        my @found = $exports->()->@*;
        return \@found if @found >= $want;
        sleep 0.02;
    }
    return $exports->();
};

$processor->process({ item => $_ }) for 1 .. 3;

my @first = $wait_for_exports->(1)->@*;
is( scalar @first, 1, 'the first batch was exported' );

my ( undef, $first_pid, $first_count ) = $first[0]->@*;
isnt( $first_pid, $$, 'the export ran in a subprocess' );
is( $first_count, 3, 'the subprocess exported the whole batch' );

kill 'KILL', $first_pid;
waitpid $first_pid, 0;

# Handing the next batch to the dead child fails. It is reported as
# dropped instead of being exported in this process, where a failing
# exporter would block the application.
$processor->process({ item => $_ }) for 4 .. 6;

is(
    $processor->dropped,
    [ [ 'subprocess-failed', 3 ] ],
    'the batch that could not be handed over is reported as dropped'
);

# The failure must not poison the processor: a later batch spawns a fresh
# export child and goes out as usual.
$processor->process({ item => $_ }) for 7 .. 9;

my @second = $wait_for_exports->(2)->@*;
is( scalar @second, 2, 'a fresh export child took the next batch' );

my ( undef, $second_pid, $second_count ) = $second[1]->@*;
isnt( $second_pid, $first_pid, 'the respawned export child is a new process' );
isnt( $second_pid, $$, 'the respawned export still ran in a subprocess' );
is( $second_count, 3, 'the respawned child exported the whole batch' );

is(
    $processor->dropped,
    [ [ 'subprocess-failed', 3 ] ],
    'the respawned export reported no further drops'
);

$processor->shutdown->get;

done_testing;
