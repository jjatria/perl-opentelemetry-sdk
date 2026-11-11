use Object::Pad ':experimental(init_expr)';
# ABSTRACT: A batched OpenTelemetry processor

package OpenTelemetry::Processor::Batch;

our $VERSION = '0.102';

# TODO: If we move the different base implementations of processors
# to the top-level, that still leaves the specific implementations
# for Traces / Metrics / Logs to exist somewhere else.
# This works, although we need to be careful about clarifying what
# the expectations are for classes in each namespace, and the what
# are the interfaces they expose.
# In all honesty, this separation ended up looking a lot better than
# expected.
class OpenTelemetry::Processor::Batch :does(OpenTelemetry::Processor) {
    use Errno qw( EINTR );
    use Feature::Compat::Defer;
    use Feature::Compat::Try;
    use Future::AsyncAwait;
    use IO::Async::Channel ();
    use IO::Handle ();
    use OpenTelemetry::Common qw( config timeout_timestamp maybe_timeout );
    use OpenTelemetry::Constants -export;
    use OpenTelemetry::SDK::Lock;
    use OpenTelemetry::X;
    use OpenTelemetry;
    use POSIX qw( _exit WNOHANG );
    use Scalar::Util 'blessed';
    use Socket qw( AF_UNIX SOCK_STREAM );
    use Time::HiRes qw( CLOCK_MONOTONIC clock_gettime sleep );

    my $logger = OpenTelemetry::Common::internal_logger;

    use Metrics::Any '$metrics', strict => 1,
        name_prefix => [qw( otel processor batch )];

    $metrics->make_gauge( 'buffer_use',
        name        => [qw( buffer use )],
        description => 'Ratio between maximum queue size and the size of the queue at export time',
    );

    # Commands to the export subprocess travel over one
    # IO::Async::Channel, as [ $type, $args, $want_ack ] array
    # references; every command that asks for one is answered on a
    # second channel with the export result as a scalar reference. Both
    # ends of both channels run in the channel's synchronous mode:
    # blocking send and recv over a socketpair, with no event loop
    # anywhere. The Storable codec is chosen explicitly so the framing
    # does not depend on which optional serialisers are installed; it
    # round-trips the Object::Pad based record and span classes.
    my $sync_channel = sub ( $handle ) {
        $handle->blocking( 1 );
        my $channel = IO::Async::Channel->new( codec => 'Storable' );
        $channel->setup_sync_mode( $handle );
        return $channel;
    };

    # Calls one of the exporter's methods and reduces its result to a
    # plain export result code. The exporter interface defines these
    # methods as synchronous (only shutdown/force_flush return futures);
    # a future that comes back is expected to have completed already,
    # since the export subprocess has no event loop to drive it. Nothing
    # here ever dies: failures report as EXPORT_RESULT_FAILURE.
    my $sync_call = sub ( $code ) {
        my $result;
        try {
            $result = $code->();
        }
        catch ($e) {
            undef $result;
        };

        if ( blessed $result && $result->isa('Future') ) {
            return EXPORT_RESULT_TIMEOUT
                unless $result->is_ready;
            try {
                $result = $result->get;
            }
            catch ($e) {
                undef $result;
            };
        }

        return $result
            if defined $result && $result =~ /\A[012]\z/;
        return EXPORT_RESULT_FAILURE;
    };

    field $batch_size       :param //= config('BSP_MAX_EXPORT_BATCH_SIZE') //    512;
    field $exporter_timeout :param //= config('BSP_EXPORT_TIMEOUT')        // 30_000;
    field $max_queue_size   :param //= config('BSP_MAX_QUEUE_SIZE')        //  2_048;
    field $schedule_delay   :param //= config('BSP_SCHEDULE_DELAY')        //  5_000;
    field $exporter         :param;

    field $lock = OpenTelemetry::SDK::Lock->new;

    field $done :reader;
    field @queue;
    field $created_pid = $$;

    # State of the export subprocess, spawned lazily (see
    # _ensure_export_child): its pid, the command channel, and the
    # acknowledgement channel with the raw read handle beside it for
    # the deadline selector in _read_ack to watch.
    field $child_pid;
    field $cmd_channel;
    field $ack_channel;
    field $ack_read;

    ADJUST {
        die OpenTelemetry::X->create(
            Invalid => "Exporter must implement the OpenTelemetry::Exporter interface: " . ( ref $exporter || $exporter )
        ) unless $exporter && $exporter->DOES('OpenTelemetry::Exporter');

        if ( $batch_size > $max_queue_size ) {
            $logger->warn(
                'Max export batch size cannot be greater than maximum queue size when instantiating batch processor',
                {
                    batch_size => $batch_size,
                    queue_size => $max_queue_size,
                },
            );
            $batch_size = $max_queue_size;
        }
    }

    # Spawns the export subprocess unless one is already running. The
    # subprocess is a plain fork of this process that serves the commands
    # arriving on its pipe; it does not run an event loop, and the
    # exporter is used through the copy of this process's own state, so
    # no exporter object ever travels through the pipe.
    #
    # Must be called while holding $lock, as part of the same critical
    # section as the _transact that follows: another thread must not be
    # able to slip a command between the spawn and its send, or between
    # a send and its acknowledgement read.
    method _ensure_export_child {
        return if defined $child_pid;

        my ( $cmd_parent, $cmd_child );
        socketpair $cmd_parent, $cmd_child, AF_UNIX, SOCK_STREAM, 0
            or die "cannot create the export command channel: $!\n";
        my ( $ack_parent, $ack_child );
        socketpair $ack_parent, $ack_child, AF_UNIX, SOCK_STREAM, 0
            or die "cannot create the export acknowledgement channel: $!\n";

        my $pid = fork;
        die "cannot fork the export child: $!\n" unless defined $pid;

        if ( $pid == 0 ) {
            close $cmd_parent;
            close $ack_parent;

            # The child must not die on a broken pipe while answering,
            # and must not run any inherited __DIE__ handler; it leaves
            # through _exit so no END block or destructor of the process
            # it was forked from runs against shared descriptors.
            local $SIG{PIPE}    = 'IGNORE';
            local $SIG{__DIE__} = 'DEFAULT';

            $self->_export_child(
                $sync_channel->( $cmd_child ),
                $sync_channel->( $ack_child ),
            );
            _exit 0;
        }

        close $cmd_child;
        close $ack_child;

        $child_pid   = $pid;
        $cmd_channel = $sync_channel->( $cmd_parent );
        $ack_channel = $sync_channel->( $ack_parent );
        $ack_read    = $ack_parent;

        return;
    }

    method _send_command ( $type, $args, $want_ack ) {
        # The synchronous channel writes with plain blocking sends, so a
        # subprocess that has already died would raise a fatal SIGPIPE
        # here. Ignored locally, the write fails with EPIPE instead and
        # dies below, into the caller's failure handling.
        local $SIG{PIPE} = 'IGNORE';

        $cmd_channel->send([ $type, $args, $want_ack ])
            or die "cannot write to the export child: $!\n";
        return;
    }

    # Reads one acknowledgement value, blocking until it arrives or
    # $timeout (in seconds) runs out. Returns ('ok', $result) or
    # ('timeout'); the caller kills the child in the latter case, as it
    # cannot know what the child is still busy with.
    method _read_ack ( $timeout = undef ) {
        my $deadline =
            defined $timeout ? clock_gettime(CLOCK_MONOTONIC) + $timeout : undef;

        my $bits = '';
        vec( $bits, fileno $ack_read, 1 ) = 1;

        while (1) {
            if ( defined $deadline ) {
                my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
                return 'timeout' if $remaining <= 0;

                my $ready = select my $rin = $bits, undef, undef, $remaining;
                if ( !defined $ready ) {
                    redo if $! == EINTR;
                    return 'timeout';
                }
                return 'timeout' unless $ready;
            }

            # An acknowledgement is a single small write, so once the
            # selector has reported the channel readable, the whole
            # frame is there and recv will not block again.
            my $result = $ack_channel->recv;
            die "the export child closed the connection\n"
                unless defined $result;

            return 'ok', $$result;
        }
    }

    # One round of the command protocol with the export subprocess:
    # sends the command and, when an answer was requested, waits for
    # the acknowledgement. Returns ('ok', $result) or ('timeout') when
    # $want_ack is true, waiting $ack_timeout seconds (unlimited when
    # it is not given), and nothing otherwise: that handover is
    # fire-and-forget and can only fail by dying here. Must be called
    # while holding $lock, so the send and the acknowledgement read
    # cannot interleave with another thread's.
    method _transact ( $type, $args, $want_ack = 0, $ack_timeout = undef ) {
        $self->_send_command( $type, $args, $want_ack );

        return $self->_read_ack( $ack_timeout )
            if $want_ack;
        return;
    }

    # The body of the export subprocess: serves commands until the
    # command channel ends, then leaves. It never dies and never returns
    # normally except when the command asked for shutdown. A recv that
    # fails for any reason (undecodable frame, read error) ends the loop
    # just like EOF does: the stream can no longer be trusted, and the
    # parent treats the acknowledgement that never arrives as a dead
    # child.
    method _export_child ( $cmd, $ack ) {
        while (1) {
            my $command;
            try {
                $command = $cmd->recv;
            }
            catch ($e) {
                undef $command;
            };

            last
                unless defined $command;

            my ( $type, $args, $want_ack ) =
                ref $command eq 'ARRAY' ? $command->@* : ();

            my $result = EXPORT_RESULT_FAILURE;

            if ( $type ) {
                if ( $type eq 'DATA' ) {
                    $result = $sync_call->( sub { $exporter->export( $args->@* ) } );
                }
                elsif ( $type eq 'FLUSH' ) {
                    $result = $sync_call->( sub { $exporter->force_flush( $args->@* ) } );
                }
                elsif ( $type eq 'SHUTDOWN' ) {
                    $result = $sync_call->( sub { $exporter->shutdown( $args->@* ) } );
                }
            }

            if ( $want_ack ) {
                $ack->send( \$result ) or _exit 0;    # nobody left
            }

            last
                if $type && $type eq 'SHUTDOWN';
        }

        _exit 0;
    }

    # A processor inherited across a fork() can reuse none of the state
    # the parent set up: the export subprocess belongs to the parent (and
    # driving its channels from here would steal the parent's commands
    # and acknowledgements). Closing the inherited channels releases
    # only this process's copy of those descriptors, which the parent
    # still holds its own of; the subprocess itself is never waited for
    # nor signalled from here, since it is not this process's child.
    #
    # This process spawns an export subprocess of its own as soon as it
    # has a batch to send (see _ensure_export_child).
    method _adopt_into_forked_process {
        return
            if $$ == $created_pid;

        $cmd_channel->close
            if $cmd_channel;
        $ack_channel->close
            if $ack_channel;
        undef $cmd_channel;
        undef $ack_channel;
        undef $ack_read;
        undef $child_pid;

        # Anything already queued belongs to the parent's pending export
        # the parent has its own copy of every record, reinitialize ours
        @queue = ();

        $created_pid = $$;

        return;
    }

    # Closes the command pipe and reaps the subprocess, giving it
    # $timeout (in seconds, defaulting to 10) to leave on its own before
    # it is killed. Called by the process that owns the subprocess only.
    method _reap_child ( $timeout = undef ) {
        return unless defined $child_pid;

        $cmd_channel->close if $cmd_channel;
        undef $cmd_channel;

        my $deadline = clock_gettime(CLOCK_MONOTONIC) + ( $timeout // 10 );

        until ( waitpid $child_pid, WNOHANG ) {
            if ( clock_gettime(CLOCK_MONOTONIC) >= $deadline ) {
                kill 'KILL', $child_pid;
                waitpid $child_pid, 0;
                last;
            }
            sleep 0.005;
        }

        $ack_channel->close if $ack_channel;
        undef $ack_channel;
        undef $ack_read;
        undef $child_pid;

        return;
    }

    # Abandons the subprocess immediately: used when its command channel
    # can no longer be trusted (a half-written frame, or an answer that
    # never arrived).
    method _kill_child {
        return unless defined $child_pid;

        $cmd_channel->close if $cmd_channel;
        $ack_channel->close if $ack_channel;
        undef $cmd_channel;
        undef $ack_channel;
        undef $ack_read;

        kill 'KILL', $child_pid;
        waitpid $child_pid, 0;
        undef $child_pid;

        return;
    }

    method process ( @items ) {
        try {
            $self->_adopt_into_forked_process;

            my $batch = $lock->enter(
                sub {
                    my $overflow = @queue + @items - $max_queue_size;
                    if ( $overflow > 0 ) {
                        # If the buffer is full, we drop old spans first
                        # The queue is always FIFO, even for dropped spans
                        # This behaviour is not in the spec, but is
                        # consistent with the Ruby implementation.
                        # For context, the Go implementation instead
                        # blocks until there is room in the buffer.
                        splice @queue, 0, $overflow;
                        $self->report_dropped( 'buffer-full', $overflow );
                    }

                    push @queue, @items;

                    return [] if @queue < $batch_size;

                    $metrics->set_gauge_to(
                        buffer_use => @queue / $max_queue_size
                    ) if @queue;

                    [ splice @queue, 0, $batch_size ];
                }
            );

            return unless @$batch;

            my $count = scalar @$batch;

            # Hand the batch to the export subprocess and keep going:
            # this is a fire-and-forget send, its result is not waited
            # for (and cannot be reported later without an event loop to
            # watch the acknowledgement pipe).
            try {
                $lock->enter(
                    sub {
                        $self->_ensure_export_child;
                        $self->_transact( 'DATA', [ $batch, $exporter_timeout ] );
                    }
                );
            }
            catch ($e) {
                # The subprocess path is unavailable. Most likely the
                # exporter's destination is down or unreachable, and
                # exporting the batch here would block this process for
                # as long as a failing export takes to time out; losing
                # this batch is better than that. Discard the subprocess
                # state so the next batch spawns a fresh one, and report
                # the batch as dropped.
                $self->_kill_child;
                $self->report_dropped( 'subprocess-failed', $count );
            }

            return;
        }
        catch($e) {
            warn $e;
        }
    }

    method report_dropped ( $reason, $count ) { $self }

    method report_result ( $result, $count ) { $result }

    async method shutdown ( $timeout = undef ) {
        return EXPORT_RESULT_SUCCESS if $done;

        defer { $done = 1 }

        my $start = timeout_timestamp;

        # TODO: The Ruby implementation ignores whether the force_flush
        # times out. Is this correct?
        await $self->force_flush( maybe_timeout $timeout, $start );

        $self->report_dropped( 'terminating', scalar @queue ) if @queue;
        @queue = ();

        my $remaining = maybe_timeout $timeout, $start;

        # With an export subprocess running, the exporter's shutdown runs
        # there (it is the process holding the exporter's live state);
        # this process just hands over the order and reaps the child.
        # A budget already spent by the flush still gets the exporter's
        # own timeout for the shutdown step.
        if ( defined $child_pid ) {
            my @shutdown_args = defined $remaining ? ( $remaining ) : ();
            my $ack_wait =
                defined $remaining && $remaining > 0
                    ? $remaining
                    : $exporter_timeout / 1000;

            my ( $state, $ack );
            try {
                ( $state, $ack ) = $lock->enter(
                    sub { $self->_transact( 'SHUTDOWN', \@shutdown_args, 1, $ack_wait ) }
                );
            }
            catch ($e) { $state = 'died' }

            $self->_reap_child( $ack_wait );

            return $state eq 'ok' ? $ack : EXPORT_RESULT_FAILURE;
        }

        await $exporter->shutdown( maybe_timeout $timeout, $start );
    }

    async method force_flush ( $timeout = undef ) {
        return EXPORT_RESULT_SUCCESS if $done;

        $self->_adopt_into_forked_process;

        my $start = timeout_timestamp;

        my @stack = $lock->enter( sub { splice @queue, 0, @queue } );

        defer {
            # If we still have any spans left it has to be because we
            # timed out and couldn't export them. In that case, we drop
            # them and report
            $self->report_dropped( 'force-flush', scalar @stack ) if @stack;
        }

        # Flushing is synchronous by definition, so waiting for each
        # batch's acknowledgement here (rather than driving it from an
        # event loop) is exactly what the caller asked for.
        while ( @stack ) {
            my $remaining = maybe_timeout $timeout, $start;
            return EXPORT_RESULT_TIMEOUT if $timeout and !$remaining;

            my $batch = [ splice @stack, 0, $batch_size ];

            my $count = scalar @$batch;

            my ( $state, $result );
            try {
                ( $state, $result ) = $lock->enter(
                    sub {
                        $self->_ensure_export_child;
                        $self->_transact( 'DATA', [ $batch, $remaining ], 1, $remaining );
                    }
                );
            }
            catch ($e) { $state = 'died' }

            if ( $state eq 'timeout' ) {
                $self->_kill_child;
                return $self->report_result( EXPORT_RESULT_TIMEOUT, $count );
            }

            if ( $state eq 'died' ) {
                # The subprocess cannot be trusted (or could not be
                # started). Exporting this batch here would block the
                # flushing caller on a failing exporter, so the batch is
                # reported as a failed export instead, which stops the
                # flush; the next use spawns a fresh subprocess.
                $self->_kill_child;
                $result = EXPORT_RESULT_FAILURE;
            }

            $self->report_result( $result, $count );

            return $result unless $result == EXPORT_RESULT_SUCCESS;
        }

        my $remaining = maybe_timeout $timeout, $start;

        # Timeout arguments are only passed when there is one: a spent or
        # absent budget reaches the exporter as no argument at all, the
        # way the direct calls always did.
        if ( defined $child_pid ) {
            my @flush_args = defined $remaining ? ( $remaining ) : ();
            my $ack_wait =
                defined $remaining && $remaining > 0
                    ? $remaining
                    : $exporter_timeout / 1000;

            my ( $state, $result );
            try {
                ( $state, $result ) = $lock->enter(
                    sub { $self->_transact( 'FLUSH', \@flush_args, 1, $ack_wait ) }
                );
            }
            catch ($e) { $state = 'died' }

            return $result if $state eq 'ok';

            if ( $state eq 'timeout' ) {
                $self->_kill_child;
                return EXPORT_RESULT_TIMEOUT;
            }

            $self->_kill_child;
            return EXPORT_RESULT_FAILURE;
        }

        await $exporter->force_flush( maybe_timeout $timeout, $start );
    }

    method DESTROY {
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';

        # Subprocess and pipes inherited from a fork that never adopted
        # this processor belong to the parent: drop this process's copy
        # of the pipe handles, but never reap or signal the subprocess,
        # which is not this process's child. A constructor that failed
        # its required-parameter check never ran field initialisation at
        # all, so the stamp may be missing.
        if ( defined $created_pid && $$ != $created_pid ) {
            $cmd_channel->close if $cmd_channel;
            $ack_channel->close if $ack_channel;
            return;
        }

        return unless defined $child_pid;

        my $timeout = ( $exporter_timeout // 30_000 ) / 1000;

        my $state;
        try {
            $lock->enter(
                sub {
                    ( $state ) =
                        $self->_transact( 'SHUTDOWN', [ $timeout ], 1, $timeout );
                }
            );
        }
        catch ($e) { $state = 'died' }

        $self->_reap_child( $timeout );

        return;
    }
}
