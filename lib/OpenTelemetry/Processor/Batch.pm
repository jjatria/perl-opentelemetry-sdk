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

    # Records, and everything that goes with them, are handed to the
    # export subprocess, which owns the queue, the batch boundaries, and
    # the schedule. Commands travel over one IO::Async::Channel as
    # [ $type, $args, $want_ack, $id ] array references: DATA carries
    # records to queue, FLUSH and SHUTDOWN ask the subprocess to drain
    # the queue and call the exporter's flush (and, for SHUTDOWN,
    # shutdown) before acknowledging on a second channel with a hash
    # reference { id, result, exported, dropped }. Every command this
    # class sends that asks for an answer is sent and read under the
    # same lock, so at most one acknowledgement is awaited at a time and
    # late answers of abandoned flushes are recognised by their id.
    # Both ends of both channels run in the channel's synchronous mode:
    # blocking send and recv over a socketpair. The selector timeouts in
    # the subprocess and in _read_ack are what this class has instead of
    # an event loop. The exporter interface is synchronous, so no loop
    # could drive it anyway. The Storable codec is chosen explicitly so
    # the framing does not depend on which optional serialisers are
    # installed. Tt round-trips the Object::Pad based record and span
    # objects.
    #
    # The :unix layer is essential, not cosmetic: synchronous-mode
    # channels read with the buffered read(), which can pull the next
    # frame's bytes into the handle's userspace buffer. A select() on
    # the descriptor cannot see those bytes, so a selector loop would
    # wait on an apparently idle socket while a whole waiting frame sits
    # unread in that buffer. An unbuffered layer keeps read() and
    # select() looking at the same bytes.
    my $sync_channel = sub ( $handle ) {
        $handle->blocking( 1 );
        my $channel = IO::Async::Channel->new( codec => 'Storable' );
        $channel->setup_sync_mode( $handle );
        binmode $handle, ':unix';
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
    field $created_pid = $$;

    # State of the export subprocess, spawned lazily (see
    # _ensure_export_child): its pid, the command channel, and the
    # acknowledgement channel with the raw read handle beside it for
    # the deadline selector in _read_ack to watch. The id sent with
    # every acknowledgement comes from $ack_seq, so answers that arrive
    # after their reader gave up can be recognised and discarded.
    field $child_pid;
    field $cmd_channel;
    field $ack_channel;
    field $ack_read;
    field $ack_seq = 0;

    method procname {
        return 'otel-batch-proc';
    }

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

        if ( $schedule_delay < 0 ) {
            $logger->warn(
                'Schedule delay cannot be negative when instantiating batch processor',
                {
                    schedule_delay => $schedule_delay,
                },
            );
            $schedule_delay = 5_000;
        }
    }

    # Spawns the export subprocess unless one is already running. The
    # subprocess is a plain fork of this process: it owns the queue of
    # records this process has sent it, exports full batches and due
    # partial ones on its own, and uses the exporter through the copy of
    # this process's own state, so no exporter object ever travels
    # through the pipe.
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

            $0 = $self->procname;

            $self->_export_child(
                $sync_channel->( $cmd_child ),
                $cmd_child,
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

    method _send_command ( $type, $args, $want_ack, $id ) {
        # The synchronous channel writes with plain blocking sends, so a
        # subprocess that has already died would raise a fatal SIGPIPE
        # here. Ignored locally, the write fails with EPIPE instead and
        # dies below, into the caller's failure handling.
        local $SIG{PIPE} = 'IGNORE';

        $cmd_channel->send([ $type, $args, $want_ack, $id ])
            or die "cannot write to the export child: $!\n";
        return;
    }

    # Reads acknowledgements until one with $wanted_id arrives, blocking
    # until then or until $timeout (in seconds) runs out. Answers of
    # flushes this process already gave up on still carry drop reports
    # worth applying, and are discarded afterwards. Returns
    # ('ok', $frame) or ('timeout'); the caller decides what to do with
    # a subprocess that did not answer in time.
    method _read_ack ( $wanted_id, $timeout = undef ) {
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
            my $frame = $ack_channel->recv;
            die "the export child closed the connection\n"
                unless defined $frame;

            if ( ref $frame eq 'HASH' && ( my $dropped = $frame->{dropped} ) ) {
                $self->report_dropped( $_, $dropped->{$_} )
                    for keys $dropped->%*;
            }

            next if ref $frame ne 'HASH' || $frame->{id} != $wanted_id;

            return 'ok', $frame;
        }
    }

    # One round of the command protocol with the export subprocess:
    # sends the command and, when an answer was requested, waits for the
    # acknowledgement with that id. Returns ('ok', $frame) or
    # ('timeout') when $want_ack is true, waiting $ack_timeout seconds
    # (unlimited when it is not given), and nothing otherwise: that
    # handover is fire-and-forget and can only fail by dying here. Must
    # be called while holding $lock, so the send and the acknowledgement
    # read cannot interleave with another thread's.
    method _transact ( $type, $args, $want_ack = 0, $id = 0, $ack_timeout = undef ) {
        $self->_send_command( $type, $args, $want_ack, $id );

        return $self->_read_ack( $id, $ack_timeout )
            if $want_ack;
        return;
    }

    # The body of the export subprocess: the queue lives here, together
    # with the countdown to the next scheduled export. The loop selects
    # on the command channel with that countdown as its timeout, which
    # is what lets it export a partial batch on time even while this
    # process's creator sends it nothing. It never dies and never
    # returns normally except after answering SHUTDOWN. A recv that
    # fails for any reason (undecodable frame, read error) ends the loop
    # just like EOF does: the stream can no longer be trusted, and the
    # parent treats an acknowledgement that never arrives as a dead
    # child.
    method _export_child ( $cmd, $cmd_handle, $ack ) {
        my @queue;
        my $next_export;

        # Drop counts collected here reach the parent's reports with the
        # next acknowledgement; while no command asks for one there is no
        # way back, and these counts stay unreported.
        my %dropped;

        # Exports at most one batch, taking it from the front of the
        # queue; $timeout is the argument list for the exporter's export
        # method.
        my $export_batch = sub ( $timeout ) {
            return EXPORT_RESULT_SUCCESS
                unless @queue;

            my $now    = clock_gettime(CLOCK_MONOTONIC);
            my $batch  = [ splice @queue, 0, $batch_size ];
            my $result = $sync_call->(
                sub { $exporter->export( $batch, $timeout->@* ) } );

            # Records left behind wait for a full batch or for a new
            # countdown, which starts from this export.
            if ( @queue ) {
                $next_export = $now + $schedule_delay / 1000;
            }
            else {
                undef $next_export;
            }

            return $result;
        };

        # Empties the queue the way FLUSH and SHUTDOWN ask: every batch
        # goes out, the timeout carried by the command only bounds the
        # calls to the exporter. Returns ( first failure, count ).
        my $drain = sub ( $budget ) {
            my $deadline = defined $budget
                ? clock_gettime(CLOCK_MONOTONIC) + $budget
                : undef;

            my ( $failed, $exported );
            while ( @queue ) {
                my $remaining;
                if ( defined $deadline ) {
                    $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
                    $remaining = 0 if $remaining < 0;
                }

                $exported += $batch_size < @queue ? $batch_size : @queue;
                my $result = $export_batch->(
                    defined $remaining ? [ $remaining ] : [undef] );
                $failed //= $result
                    if $result != EXPORT_RESULT_SUCCESS;
            }

            return ( $failed, $exported // 0, $deadline );
        };

        while (1) {
            # The countdown is due: the partial batch goes out before
            # anything else is considered.
            if ( defined $next_export ) {
                my $remaining = $next_export - clock_gettime(CLOCK_MONOTONIC);
                if ( $remaining <= 0 ) {
                    $export_batch->( [ $exporter_timeout ] );
                    next;
                }
            }

            my $bits = '';
            vec( $bits, fileno $cmd_handle, 1 ) = 1;

            my $ready = select my $rin = $bits, undef, undef,
                defined $next_export
                    ? $next_export - clock_gettime(CLOCK_MONOTONIC)
                    : undef;

            if ( !defined $ready ) {
                redo if $! == EINTR;
                last;    # the selector failed for good
            }

            next
                unless $ready;

            my $command;
            try {
                $command = $cmd->recv;
            }
            catch ($e) {
                undef $command;
            };

            last
                unless defined $command;

            my ( $type, $args, $want_ack, $id ) =
                ref $command eq 'ARRAY' ? $command->@* : ();

            my $result   = EXPORT_RESULT_FAILURE;
            my $exported = 0;

            if ( $type ) {
                if ( $type eq 'DATA' ) {
                    push @queue, $args->@*;

                    # If the buffer is full, the oldest records go: the
                    # queue is always FIFO, even for dropped records.
                    # This behaviour is not in the spec, but is
                    # consistent with the Ruby implementation.
                    if ( my $overflow = @queue - $max_queue_size ) {
                        splice @queue, 0, $overflow;
                        $dropped{'buffer-full'} += $overflow;
                    }

                    # The first record to reach an empty queue starts
                    # the countdown to the next scheduled export.
                    $next_export //= clock_gettime(CLOCK_MONOTONIC)
                        + $schedule_delay / 1000;

                    $export_batch->( [ $exporter_timeout ] )
                        while @queue >= $batch_size;
                }
                elsif ( $type eq 'FLUSH' || $type eq 'SHUTDOWN' ) {
                    my ( $budget ) = $args->@*;

                    my ( $failed, $count, $deadline ) = $drain->( $budget );
                    $exported = $count;

                    my $remaining;
                    if ( defined $deadline ) {
                        $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
                        $remaining = 0 if $remaining < 0;
                    }

                    my $flushed = $sync_call->(
                        sub {
                            $exporter->force_flush(
                                defined $remaining ? ( $remaining ) : ()
                            );
                        }
                    );
                    $failed //= $flushed
                        if $flushed != EXPORT_RESULT_SUCCESS;

                    $result = $failed // $flushed;

                    if ( $type eq 'SHUTDOWN' ) {
                        my $down = $sync_call->(
                            sub {
                                $exporter->shutdown(
                                    defined $remaining ? ( $remaining ) : ()
                                );
                            }
                        );

                        # A shutdown that itself failed is reported as
                        # such; when it went through, any failure of the
                        # flush it implies is what gets reported.
                        $result = $down
                            if $down != EXPORT_RESULT_SUCCESS;
                    }
                }
            }

            if ( $want_ack ) {
                $ack->send({
                    id       => $id,
                    result   => $result,
                    exported => $exported,
                    dropped  => { %dropped },
                }) or _exit 0;    # nobody left

                %dropped = ();
            }

            last
                if $type && $type eq 'SHUTDOWN';
        }

        _exit 0;
    }

    # A processor inherited across a fork() can reuse none of the state
    # the parent set up: the export subprocess belongs to the parent (it
    # holds the records the parent sent, and driving its channels from
    # here would steal the parent's commands and acknowledgements).
    # Closing the inherited channels releases only this process's copy
    # of those descriptors, which the parent still holds its own of; the
    # subprocess itself is never waited for nor signalled from here,
    # since it is not this process's child.
    #
    # This process spawns an export subprocess of its own as soon as it
    # receives a record (see _ensure_export_child).
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

            # A signal handler inherited from a test harness or the
            # application could make the sleep die; the loop just keeps
            # turning until the deadline.
            try { sleep 0.005 } catch ($e) { }
        }

        $ack_channel->close if $ack_channel;
        undef $ack_channel;
        undef $ack_read;
        undef $child_pid;

        return;
    }

    # Abandons the subprocess immediately: used when its command channel
    # can no longer be trusted (a half-written frame, an answer that
    # never arrived, or a shutdown that cannot wait for the drain).
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

    # Hands the records to the export subprocess and keeps going. The
    # subprocess queues them there, and its own loop takes them out: a
    # full batch right away, a partial one when the schedule delay runs
    # out, whether or not this process keeps using the processor.
    #
    # A handover that fails (the subprocess having died since the last
    # call) is retried once on a freshly spawned subprocess: replacing
    # the subprocess is cheap, these records were never delivered, and
    # exporting them here is not an option (a failing exporter would
    # block this caller for as long as it takes to time out). Only when
    # the retry fails too are the records reported as dropped.
    method process ( @items ) {
        try {
            # The spec asks a processor to ignore the records it gets
            # after it has been shut down.
            return
                if $done;

            return
                unless @items;

            $self->_adopt_into_forked_process;

            my $count = @items;

            my $handover = sub {
                $lock->enter(
                    sub {
                        $self->_ensure_export_child;
                        $self->_transact( 'DATA', \@items );
                    }
                );
                return;
            };

            # This is a fire-and-forget send: the result of the eventual
            # export is not waited for (and, for a scheduled export,
            # there is no caller here to report it to).
            try {
                $handover->();
            }
            catch ($e) {
                $self->_kill_child;

                try {
                    $handover->();
                }
                catch ($e) {
                    # The subprocess path is unavailable twice over.
                    # Discard the subprocess state so the next call
                    # spawns a fresh one, and report the records as
                    # dropped.
                    $self->_kill_child;
                    $self->report_dropped( 'subprocess-failed', $count );
                };
            }

            return;
        }
        catch($e) {
            warn $e;
        }
    }

    method report_dropped ( $reason, $count ) { $self }

    method report_result ( $result, $count ) { $result }

    # The result of the flush implied by the specification's shutdown.
    # With a subprocess running, the drain and the exporter calls it
    # involves all happen there (it is the process holding the records
    # and the exporter's live state); this process just hands over the
    # order and waits. A SHUTDOWN that cannot be waited for (the flush
    # of the shutdown timed out, or the subprocess stopped answering)
    # means the subprocess is killed and the records it still held are
    # lost.
    async method shutdown ( $timeout = undef ) {
        return EXPORT_RESULT_SUCCESS if $done;

        defer { $done = 1 }

        my $start = timeout_timestamp;

        if ( defined $child_pid ) {
            my @shutdown_args = ( maybe_timeout $timeout, $start );
            my $ack_wait =
                @shutdown_args && $shutdown_args[0] > 0
                    ? $shutdown_args[0]
                    : $exporter_timeout / 1000;

            my $id = ++$ack_seq;
            my ( $state, $frame );
            try {
                ( $state, $frame ) = $lock->enter(
                    sub {
                        $self->_transact( 'SHUTDOWN', \@shutdown_args, 1, $id, $ack_wait );
                    }
                );
            }
            catch ($e) { $state = 'died' }

            $self->_reap_child( $ack_wait );

            my $result =
                  $state eq 'ok'      ? $frame->{result}
                : $state eq 'timeout' ? EXPORT_RESULT_TIMEOUT
                :                       EXPORT_RESULT_FAILURE;

            return $result;
        }

        my $flush = await $self->force_flush( maybe_timeout $timeout, $start );

        my $result = await $exporter->shutdown( maybe_timeout $timeout, $start );

        return $result
            unless !defined $result || $result == EXPORT_RESULT_SUCCESS;
        return $flush;
    }

    # Orders the export subprocess to drain its queue and flush the
    # exporter, waiting for it to acknowledge within $timeout (in
    # seconds). The subprocess was told to drain to the end, so when
    # this wait times out the subprocess is left running: the records it
    # did not finish with stay in its queue and go out with its next
    # scheduled export. A subprocess that died in the attempt is
    # replaced when the next record arrives.
    async method force_flush ( $timeout = undef ) {
        return EXPORT_RESULT_SUCCESS if $done;

        $self->_adopt_into_forked_process;

        my $start = timeout_timestamp;

        unless ( defined $child_pid ) {
            return await $exporter->force_flush( maybe_timeout $timeout, $start );
        }

        my @flush_args = ( maybe_timeout $timeout, $start );
        my $ack_wait =
            @flush_args && $flush_args[0] > 0
                ? $flush_args[0]
                : $exporter_timeout / 1000;

        my $id = ++$ack_seq;
        my ( $state, $frame );
        try {
            ( $state, $frame ) = $lock->enter(
                sub {
                    $self->_ensure_export_child;
                    $self->_transact( 'FLUSH', \@flush_args, 1, $id, $ack_wait );
                }
            );
        }
        catch ($e) { $state = 'died' }

        if ( $state eq 'timeout' ) {
            return $self->report_result( EXPORT_RESULT_TIMEOUT, 0 );
        }

        if ( $state eq 'died' ) {
            $self->_kill_child;
            return $self->report_result( EXPORT_RESULT_FAILURE, 0 );
        }

        return $self->report_result( $frame->{result}, $frame->{exported} );
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
        my $id      = ++$ack_seq;

        my $state;
        try {
            $lock->enter(
                sub {
                    ( $state ) =
                        $self->_transact( 'SHUTDOWN', [ $timeout ], 1, $id, $timeout );
                }
            );
        }
        catch ($e) { $state = 'died' }

        $self->_reap_child( $timeout );

        return;
    }
}

1;
