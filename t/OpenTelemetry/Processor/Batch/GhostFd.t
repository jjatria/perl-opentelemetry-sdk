#!/usr/bin/env perl

use Test2::V0;

# The export subprocess must not keep a copy of descriptors that belong
# to the process that forked it: a client connection inherited from the
# middle of a request stays half-open as long as the subprocess lives,
# and a client reusing that connection hangs forever with no worker
# reading it. See the ghost-socket failure this regression test exists
# for.

use lib 't/lib';
use IO::Select;
use OpenTelemetry::Constants -export;
use OpenTelemetry::SDK::Trace::Span::Processor::Batch;
use Local::Exporter::File;
use Socket qw( AF_UNIX SOCK_STREAM );

my $exporter = Local::Exporter::File->new;
my $processor = OpenTelemetry::SDK::Trace::Span::Processor::Batch->new(
    exporter   => $exporter,
    batch_size => 10,
);

# The "client connection": one end the request would be serving on, one
# end the "client".
my ( $served, $peer );
socketpair $served, $peer, AF_UNIX, SOCK_STREAM, 0 or die $!;

# Handing the record over spawns the subprocess, which inherits the
# served socket.
$processor->process( { name => 'span' } );

# The serving process is done with its copy; only an inherited one in
# the subprocess could still be holding the connection open.
close $served or die $!;

my $select = IO::Select->new( $peer );
ok $select->can_read( 5 ), 'the peer sees the connection end within 5s';
is sysread( $peer, my $nothing, 1 ), 0, 'EOF: no inherited copy is left open';

close $peer;

# And the subprocess is still the healthy owner of its own channels:
# the descriptor sweep must not have closed anything it runs on.
is $processor->force_flush->get, EXPORT_RESULT_SUCCESS, 'flush still works';
is scalar( grep { $_->[0] eq 'export' } $exporter->calls->@* ), 1,
    'the exporter exported once';

done_testing;
