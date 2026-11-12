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

# A processor that remembers its drop reports, which is how records that
# no export child could take are surfaced now that no batch is ever
# exported inline as a fallback.
class Local::BatchProbe :isa(OpenTelemetry::Processor::Batch) {
    field @dropped;

    method report_dropped ( $reason, $count ) {
        push @dropped, [ "$reason", 0 + $count ];
        return $self;
    }

    method dropped { \@dropped }
}

# A processor whose export child can never be started: both handover
# attempts fail, which is what the dropped report is for.
class Local::BatchUnspawnable :isa(Local::BatchProbe) {
    method _ensure_export_child { die "cannot fork the export child: Test\n" }
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

# Handing the next records to the dead child fails. They are not
# exported in this process, where a failing exporter would block the
# application; instead they are handed to a freshly spawned export child
# and go out through it, without any drop being reported.
$processor->process({ item => $_ }) for 4 .. 6;

my @second = $wait_for_exports->(2)->@*;
is( scalar @second, 2, 'a fresh export child took the records' );

my ( undef, $second_pid, $second_count ) = $second[1]->@*;
isnt( $second_pid, $first_pid, 'the replacement export child is a new process' );
isnt( $second_pid, $$, 'the replacement export still ran in a subprocess' );
is( $second_count, 3, 'the replacement child exported the whole batch' );

is( $processor->dropped, [], 'the records the dead child never took were not lost' );

# The failure must not poison the processor: a later batch goes out on
# the same replacement child.
$processor->process({ item => $_ }) for 7 .. 9;

my @third = $wait_for_exports->(3)->@*;
is( scalar @third, 3, 'the next batch went out too' );
is( $third[2]->[2], 3, 'the whole batch was exported' );

$processor->shutdown->get;

# Only when the subprocess cannot be reached at all (here: it can never
# even be spawned, so the retry fails as well) are the records reported
# as dropped.
my $unspawnable = Local::BatchUnspawnable->new(
    batch_size => 3,
    exporter   => Local::Exporter::PidFile->new,
);

$unspawnable->process({ item => $_ }, { item => $_ + 1 }, { item => $_ + 2 })
    for 42;

is(
    $unspawnable->dropped,
    [ [ 'subprocess-failed', 3 ] ],
    'records no subprocess could take are reported as dropped'
);

done_testing;
