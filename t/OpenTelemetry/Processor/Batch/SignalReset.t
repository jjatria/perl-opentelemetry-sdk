#!/usr/bin/env perl

use Test2::V0;

# The export subprocess must not keep the signal handlers of the process
# it was forked from: a request-scoped handler that dies (a timeout one,
# most likely) would otherwise run inside the subprocess on the next
# signal, doing the emitting process's shutdown work against its state.

use lib 't/lib';
use experimental 'signatures';
use Feature::Compat::Try;
use POSIX qw( WNOHANG );
use Time::HiRes qw( sleep );
use OpenTelemetry::Constants -export;
use OpenTelemetry::SDK::Trace::Span::Processor::Batch;
use Local::Exporter::File;

plan skip_all => 'this test locates the export child through /proc'
    unless -d '/proc/self';

my $exporter = Local::Exporter::File->new;
my $processor = OpenTelemetry::SDK::Trace::Span::Processor::Batch->new(
    exporter   => $exporter,
    batch_size => 10,
);

# A CODE handler of the kind a request timeout installs, dying if it
# ever runs. WINCH's default action is to be ignored, so the subprocess
# survives this signal exactly when the handler was dropped, and dies
# when it was kept.
local $SIG{WINCH} = sub { die "the inherited handler ran\n" };

$processor->process( { name => 'span' } );

sub export_kid_of ( $dir ) {
    open my $status, '<', "/proc/$dir/status" or return;
    my ( $name, $ppid );
    while ( my $line = <$status> ) {
        $name = $1 if $line =~ /^Name:\s+(\S+)/;
        $ppid = $1 if $line =~ /^PPid:\s+(\d+)/;
    }
    close $status;

    return unless defined $ppid && $ppid == $$
        && defined $name && $name =~ /^otel-batch/;
    return 0 + $dir;
}

my @kids = map { export_kid_of( $_ ) }
    grep { /^\d+\z/ } do { opendir my $dir, '/proc'; readdir $dir };

my ( $child_pid ) = @kids;
ok defined $child_pid, 'located the export child';

# Past the handler reset (which happens immediately after the fork),
# then aim at the signal whose inherited handler would die on.
try { sleep 0.2 } catch ($e) { };
kill WINCH => $child_pid;
try { sleep 0.2 } catch ($e) { };

is waitpid( $child_pid, WNOHANG ), 0,
    'the subprocess survived a signal its inherited handler dies on';

is $processor->force_flush->get, EXPORT_RESULT_SUCCESS,
    'and it still serves commands afterwards';
is scalar( grep { $_->[0] eq 'export' } $exporter->calls->@* ), 1,
    'exporting the record it was given';

is ref $SIG{WINCH}, 'CODE', 'the emitting process kept its own handler';

done_testing;
