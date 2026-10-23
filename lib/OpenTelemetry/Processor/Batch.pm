use Object::Pad ':experimental(init_expr)';
# ABSTRACT: A batched OpenTelemetry processor

package OpenTelemetry::Processor::Batch;

our $VERSION = '0.101';

# TODO: If we move the different base implementations of processors
# to the top-level, that still leaves the specific implementations
# for Traces / Metrics / Logs to exist somewhere else.
# This works, although we need to be careful about clarifying what
# the expectations are for classes in each namespace, and the what
# are the interfaces they expose.
# In all honesty, this separation ended up looking a lot better than
# expected.
class OpenTelemetry::Processor::Batch :does(OpenTelemetry::Processor) {
    use Feature::Compat::Defer;
    use Feature::Compat::Try;
    use Future::AsyncAwait;
    use IO::Async::Function;
    use IO::Async::Loop;
    use IO::Async::Timer::Countdown;
    use Mutex;
    use OpenTelemetry::Common qw( config timeout_timestamp maybe_timeout );
    use OpenTelemetry::Constants -export;
    use OpenTelemetry::X;
    use OpenTelemetry;
    use Scalar::Util qw( refaddr weaken );

    my $logger = OpenTelemetry::Common::internal_logger;

    use Metrics::Any '$metrics', strict => 1,
        name_prefix => [qw( otel processor batch )];

    $metrics->make_gauge( 'buffer_use',
        name        => [qw( buffer use )],
        description => 'Ratio between maximum queue size and the size of the queue at export time',
    );

    field $batch_size       :param //= config('BSP_MAX_EXPORT_BATCH_SIZE') //    512;
    field $exporter_timeout :param //= config('BSP_EXPORT_TIMEOUT')        // 30_000;
    field $max_queue_size   :param //= config('BSP_MAX_QUEUE_SIZE')        //  2_048;
    field $schedule_delay   :param //= config('BSP_SCHEDULE_DELAY')        //  5_000;
    field $exporter         :param;

    field $lock = Mutex->new;

    field $done :reader;
    field $function;
    field $timer;
    field %running;
    field @queue;

    # Every record has a number: the number of records that were queued
    # before it. $front is the number of the first record in the queue.
    field $front = 0;

    # The flushes that run now, as weak references. Each one has the
    # number below which it covers the records, and the exports of those
    # records that it has to wait for.
    field %flushes;

    # Start the countdown to the next scheduled export, unless it already
    # runs, an export is running, or the queue is empty.
    method $start_timer_if_idle () {
        return unless $timer && $timer->loop;
        return if $timer->is_running || %running || !@queue;
        $timer->start;
    }

    # Take up to $count records from the front of the queue. Call this
    # while holding the lock. Returns the number of the first record, and
    # the records.
    method $take ( $count ) {
        my $first = $front;
        my @records = splice @queue, 0, $count;
        $front += @records;
        return ( $first, \@records );
    }

    # Returns a future that is ready when $future is, or when the time
    # before the timeout runs out, whichever comes first
    method $within_timeout ( $future, $timeout, $start ) {
        my $remaining = maybe_timeout $timeout, $start;
        return $future unless defined $remaining;

        Future->wait_any(
            $future,
            IO::Async::Loop->new->delay_future( after => $remaining ),
        );
    }

    # Forget the flushes that have ended. %flushes only holds weak
    # references, so their entries become undefined.
    method $forget_ended_flushes () {
        delete $flushes{$_} for grep !defined $flushes{$_}, keys %flushes;
    }

    # Add the future of an export to every running flush that covers its
    # first record, so that the flush sees its result, even if the export
    # ends before the flush looks at it
    method $add_to_flushes ( $future, $first ) {
        $self->$forget_ended_flushes;

        for my $flush ( values %flushes ) {
            $flush->{exports}{ refaddr $future } = $future
                if $first < $flush->{end};
        }
    }

    # Keep the future of an export in %running until the export ends,
    # with the number of its first record. Every export stops the
    # countdown when it starts, and when the last running export ends, the
    # countdown starts again. So the countdown never runs while an export
    # runs, and the delay counts from the end of the previous export.
    method $track_running_export ( $future, $first ) {
        $timer->stop if $timer && $timer->loop;

        my $key = refaddr $future;
        $running{$key} = [ $future, $first ];

        $self->$add_to_flushes( $future, $first );

        weaken( my $weak = $self );
        $future->on_ready( sub {
            return unless $weak;
            delete $running{$key};
            $weak->$start_timer_if_idle;
        });
    }

    # Start the export of a batch that starts with record number $first,
    # and report its result when it ends. Returns the future of the
    # export. Dies if the export cannot be dispatched.
    method $start_export ( $first, $batch, $timeout ) {
        my $count = scalar @$batch;

        my $export;
        try {
            $export = $function->call(
                args => [ $exporter, $batch, $timeout ],
            );
        }
        catch ($e) {
            # The records have left the queue. A flush that covers them
            # must see that they were not exported.
            $self->$add_to_flushes(
                Future->done(EXPORT_RESULT_FAILURE), $first
            );

            die $e;
        }

        $self->$track_running_export( $export, $first );

        # Retain the future so we don't have to wait for it ourselves
        $export->on_ready( sub ( $f ) {
            $self->report_result(
                $f->is_done ? $f->result : EXPORT_RESULT_FAILURE, $count
            );
        })->retain;
    }

    method $export_on_timer () {
        my ( $first, $batch ) = $lock->enter( sub {
            $self->$take($batch_size);
        });

        return unless @$batch;

        try { $self->$start_export( $first, $batch, $exporter_timeout ) }
        catch ($e) {
            $self->report_result( EXPORT_RESULT_FAILURE, scalar @$batch );

            # If the export could not be dispatched, nothing ends to start
            # the countdown for the records left in the queue
            $self->$start_timer_if_idle;
        }
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
                { schedule_delay => $schedule_delay },
            );
            $schedule_delay = 5_000;
        }

        # This is a non-standard variable, so we make it Perl-specific
        my $max_workers = $ENV{OTEL_PERL_BSP_MAX_WORKERS};

        $function = IO::Async::Function->new(
            $max_workers ? ( max_workers => $max_workers ) : (),

            code => sub ( $exporter, $batch, $timeout ) {
                $exporter->export( $batch, $timeout );
            },
        );

        my $loop = IO::Async::Loop->new;
        $loop->add($function);

        # The timer only fires while the IO::Async loop runs. The callback
        # holds a weak reference, so the timer does not keep the processor
        # alive.
        weaken( my $weak = $self );
        $timer = IO::Async::Timer::Countdown->new(
            delay     => $schedule_delay / 1000,
            on_expire => sub {
                $weak->$export_on_timer if $weak;
            },
        );

        $loop->add($timer);
    }

    method process ( @items ) {
        try {
            my ( $first, $batch ) = $lock->enter(
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
                        $front += $overflow;
                        $self->report_dropped( 'buffer-full', $overflow );
                    }

                    push @queue, @items;

                    if ( @queue < $batch_size ) {
                        $self->$start_timer_if_idle;
                        return;
                    }

                    $metrics->set_gauge_to(
                        buffer_use => @queue / $max_queue_size
                    ) if @queue;

                    $self->$take($batch_size);
                }
            );

            # A full batch does not wait for the timer, or for other
            # exports that are running
            if ( $batch ) {
                try {
                    $self->$start_export( $first, $batch, $exporter_timeout );
                }
                catch ($e) {
                    warn $e;
                    $self->$start_timer_if_idle;
                }
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

        # Stop the timer before the final export, so it cannot start
        # another export while we flush the queue
        if ( $timer and my $loop = $timer->loop ) {
            $timer->stop;
            $loop->remove($timer);
        }

        # TODO: The Ruby implementation ignores whether the force_flush
        # times out. Is this correct?
        await $self->force_flush( maybe_timeout $timeout, $start );

        $self->report_dropped( 'terminating', scalar @queue ) if @queue;
        $front += @queue;
        @queue = ();

        # Wait for every export, also for calls that still wait for a
        # worker. Stopping the function only waits for the workers that
        # run now, and a call that waits would get a new worker after that.
        if ( my @exports = map $_->[0], values %running ) {
            await Future->wait_all( map $_->without_cancel, @exports );
        }

        await $function->stop if $function->workers;

        await $exporter->shutdown( maybe_timeout $timeout, $start );
    }

    async method force_flush ( $timeout = undef ) {
        return EXPORT_RESULT_SUCCESS if $done;

        my $start = timeout_timestamp;

        # The records that were queued before this call have numbers
        # below $end. The exports that run now have some of them, and
        # every later export of them adds itself to this flush. %flushes
        # only holds a weak reference: when this method ends, also if it
        # is cancelled, the entry becomes undefined, and the next cleanup
        # deletes it.
        my $end = $lock->enter( sub { $front + @queue } );

        my $flush = {
            end     => $end,
            exports => { map { refaddr $_->[0] => $_->[0] } values %running },
        };

        $self->$forget_ended_flushes;
        weaken( $flushes{ refaddr $flush } = $flush );

        # Export those records that are still in the queue, one batch at a
        # time. Until we take them, a full batch or the timer can take some
        # of them first, and the wait below covers those exports too. If we
        # time out, or if this flush is cancelled, the records that we did
        # not take stay in the queue, and our exports go on.
        while (1) {
            my $remaining = maybe_timeout $timeout, $start;
            return EXPORT_RESULT_TIMEOUT if $timeout and !$remaining;

            my ( $first, $batch ) = $lock->enter( sub {
                $front < $end ? $self->$take($batch_size) : ();
            });

            last unless $batch;

            my $export;
            try {
                $export = $self->$start_export( $first, $batch, $remaining );
            }
            catch ($e) {
                return $self->report_result(
                    EXPORT_RESULT_FAILURE, scalar @$batch
                );
            }

            my $wait = Future->wait_all( $export->without_cancel );
            await $self->$within_timeout( $wait, $timeout, $start );

            # wait_any cancels $wait if the delay ends first
            return EXPORT_RESULT_TIMEOUT unless $wait->is_done;

            my $result = $export->is_done
                ? $export->result : EXPORT_RESULT_FAILURE;

            return $result unless $result == EXPORT_RESULT_SUCCESS;
        }

        # Wait for every export that has any of those records
        if ( my @pending = values %{ $flush->{exports} } ) {
            my $all = Future->wait_all( map $_->without_cancel, @pending );
            await $self->$within_timeout( $all, $timeout, $start );

            # wait_any cancels $all if the delay ends first
            return EXPORT_RESULT_TIMEOUT unless $all->is_done;

            for my $export ( @pending ) {
                my $result = $export->is_done
                    ? $export->result : EXPORT_RESULT_FAILURE;

                return $result unless $result == EXPORT_RESULT_SUCCESS;
            }
        }

        await $exporter->force_flush( maybe_timeout $timeout, $start );
    }

    method DESTROY {
        try {
            if ( $timer and my $loop = $timer->loop ) {
                $timer->stop;
                $loop->remove($timer);
            }

            $function->stop if $function;
        }
        catch ($e) { }
    }
}
