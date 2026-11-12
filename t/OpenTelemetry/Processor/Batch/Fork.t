#!/usr/bin/env perl

use Test2::V0;

use File::Temp 'tempfile';
use Feature::Compat::Try;
use POSIX '_exit';

use OpenTelemetry::Constants -trace_export;
use OpenTelemetry::Processor::Batch;
use OpenTelemetry::SDK::Logs::LoggerProvider;
use OpenTelemetry::SDK::Logs::LogRecord::Processor::Batch;

use lib 't/lib';
use Local::Exporter::EnvFile;
use Local::Exporter::File;

# A child that inherits a batch processor must keep working: it spawns an
# export child of its own, while the parent keeps its own queue and its own
# export child.
my $exporter = Local::Exporter::File->new;

my $processor = OpenTelemetry::Processor::Batch->new(
    batch_size => 3,
    exporter   => $exporter,
);

# Leave some records pending in the parent's export child, below its
# batch size (and therefore not exported there yet).
$processor->process({ parent => $_ }) for 1 .. 2;

my $child = fork;
defined $child or plan skip_all => "cannot fork: $!";

if ( !$child ) {
    my $ok = 1;
    try {
        local $SIG{ALRM} = sub { die "wedge\n" };
        alarm 20;

        $processor->process({ child => $_ }) for 1 .. 3;

        die "flush failed\n"
            unless $processor->force_flush->get == TRACE_EXPORT_SUCCESS;

        alarm 0;
    }
    catch ($e) { $ok = 0 };

    _exit $ok ? 0 : 1;
}

waitpid $child, 0;
is $?, 0, 'the forked child used the processor without wedging';

# The child exported its batch and nothing else: the records the
# parent had sent to its own export child are still pending there, and
# must not be sent twice.
is $exporter->calls, [
    [ 'export', [ { child => 1 }, { child => 2 }, { child => 3 } ], 30_000 ],
    [ 'force_flush' ],
], 'the child exported exactly its own records';

$exporter->reset;

# The parent's records survived the child's adoption untouched, and its
# export path still works after the child is gone.
is $processor->force_flush->get, TRACE_EXPORT_SUCCESS,
    'the parent can still flush its own queue';

is $exporter->calls, [
    [ 'export', [ { parent => 1 }, { parent => 2 } ], undef ],
    [ 'force_flush' ],
], 'the parent exported exactly its own records';

$processor->shutdown->get;

# End to end through a provider: the registry lock created in the parent
# (when materialising its logger) must self-heal in the child too.
my ( undef, $path ) = tempfile;
local $ENV{OTEL_TEST_EXPORT_FILE} = $path;

my $provider = OpenTelemetry::SDK::Logs::LoggerProvider->new;
$provider->add_log_record_processor(
    OpenTelemetry::SDK::Logs::LogRecord::Processor::Batch->new(
        batch_size => 3,
        exporter   => Local::Exporter::EnvFile->new,
    ),
);

my $logger = $provider->logger( name => 'test-parent' );
$logger->emit_record( body => 'parent' ) for 1 .. 2;

$child = fork;
defined $child or plan skip_all => "cannot fork: $!";

if ( !$child ) {
    my $ok = 1;
    try {
        local $SIG{ALRM} = sub { die "wedge\n" };
        alarm 20;

        my $kid = $provider->logger( name => 'test-child' );
        $kid->emit_record( body => 'child' ) for 1 .. 3;

        die "shutdown failed\n"
            unless $provider->shutdown->get == TRACE_EXPORT_SUCCESS;

        alarm 0;
    }
    catch ($e) { $ok = 0 };

    _exit $ok ? 0 : 1;
}

waitpid $child, 0;
is $?, 0, 'the forked child emitted through the inherited provider';

is $provider->force_flush->get, TRACE_EXPORT_SUCCESS,
    'the parent can still flush its own records';

my @lines = do {
    open my $handle, '<', $path or die "cannot read $path: $!";
    chomp( my @lines = <$handle> );
    @lines;
};

is [ grep /^export /, @lines ], [
    'export OpenTelemetry::SDK::Logs::LogRecord 3',
    'export OpenTelemetry::SDK::Logs::LogRecord 2',
], 'each process exported exactly its own records';

$provider->shutdown->get;

done_testing;
