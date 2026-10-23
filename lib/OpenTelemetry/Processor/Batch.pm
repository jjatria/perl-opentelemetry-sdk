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

    # Start the countdown to the next scheduled export, unless it already
    # runs, an export is running, or the queue is empty. Since it does not
    # start while an export runs, the delay counts from the end of the
    # previous export.
    method $start_timer_if_idle () {
        return unless $timer && $timer->loop;
        return if $timer->is_running || %running || !@queue;
        $timer->start;
    }

    # Keep the future of an export in %running until the export ends.
    # When the last running export ends, start the countdown to the next
    # scheduled export. Returns the future.
    method $track_running_export ( $future ) {
        my $key = refaddr $future;
        $running{$key} = $future;

        weaken( my $weak = $self );
        $future->on_ready( sub {
            return unless $weak;
            delete $running{$key};
            $weak->$start_timer_if_idle;
        });
    }

    # Export a full batch from the queue. It does not wait for the timer,
    # or for other exports that are running.
    method $export_batch ( $batch ) {
        # This export starts now, so stop the countdown. The end of this
        # export schedules the next one.
        $timer->stop if $timer && $timer->loop;

        my $count = scalar @$batch;
        try {
            # Retain the future so we don't have to wait for it ourselves
            $self->$track_running_export(
                $function->call( args => [ $exporter, $batch, $exporter_timeout ] )
            )->on_ready( sub ( $f ) {
                return $self->report_result( EXPORT_RESULT_FAILURE, $count )
                    unless $f->is_done;

                $self->report_result( $f->result, $count );
            })->retain;
        }
        catch ($e) {
            warn $e;
            $self->$start_timer_if_idle;
        }

        return;
    }

    async method $export_on_timer () {
        # Another export started after the timer did. Its end will
        # schedule the next export.
        return if %running;

        my $batch = $lock->enter( sub { [ splice @queue, 0, $batch_size ] } );
        return unless @$batch;

        my $count = scalar @$batch;
        try {
            my $result = await $self->$track_running_export(
                $function->call( args => [ $exporter, $batch, $exporter_timeout ] )
            );

            $self->report_result( $result, $count );
        }
        catch ($e) {
            $self->report_result( EXPORT_RESULT_FAILURE, $count );
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
                $weak->$export_on_timer->retain if $weak;
            },
        );

        $loop->add($timer);
    }

    method process ( @items ) {
        try {
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

                    if ( @queue < $batch_size ) {
                        $self->$start_timer_if_idle;
                        return [];
                    }

                    $metrics->set_gauge_to(
                        buffer_use => @queue / $max_queue_size
                    ) if @queue;

                    [ splice @queue, 0, $batch_size ];
                }
            );

            $self->$export_batch($batch) if @$batch;

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
        @queue = ();

        await $function->stop if $function->workers;

        await $exporter->shutdown( maybe_timeout $timeout, $start );
    }

    async method $flush ( $timeout = undef ) {
        return EXPORT_RESULT_SUCCESS if $done;

        my $start = timeout_timestamp;

        # Wait for exports that are still running, so that their records
        # have been exported when we return
        if ( my @pending = values %running ) {
            my $all = Future->wait_all( map $_->without_cancel, @pending );

            if ( defined( my $remaining = maybe_timeout $timeout, $start ) ) {
                await Future->wait_any(
                    $all,
                    IO::Async::Loop->new->delay_future( after => $remaining ),
                );

                # wait_any cancels $all if the delay ends first
                return EXPORT_RESULT_TIMEOUT unless $all->is_done;
            }
            else {
                await $all;
            }

            for my $export ( @pending ) {
                my $result = $export->is_done
                    ? $export->result : EXPORT_RESULT_FAILURE;

                return $result unless $result == EXPORT_RESULT_SUCCESS;
            }
        }

        my @stack = $lock->enter( sub { splice @queue, 0, @queue } );

        defer {
            # If we still have any spans left it has to be because we
            # timed out and couldn't export them. In that case, we drop
            # them and report
            $self->report_dropped( 'force-flush', scalar @stack ) if @stack;
        }

        while ( @stack ) {
            my $remaining = maybe_timeout $timeout, $start;
            return EXPORT_RESULT_TIMEOUT if $timeout and !$remaining;

            my $batch = [ splice @stack, 0, $batch_size ];

            my $count = scalar @$batch;
            try {
                my $result = await $self->$track_running_export(
                    $function->call( args => [ $exporter, $batch, $remaining ] )
                );

                $self->report_result( $result, $count );

                return $result unless $result == EXPORT_RESULT_SUCCESS;
            }
            catch ($e) {
                return $self->report_result( EXPORT_RESULT_FAILURE, $count);
            }
        }

        await $exporter->force_flush( maybe_timeout $timeout, $start );
    }

    # This is not an async method, so that cancelling the future it returns
    # does not have to unwind a defer block in an async method while it
    # waits for running exports. With Future::AsyncAwait 0.71 on Perl 5.44,
    # that crashes the interpreter.
    method force_flush ( $timeout = undef ) {
        # The flush exports the queue now, so stop the countdown. The end
        # of the flush schedules the next export.
        $timer->stop if $timer && $timer->loop;

        $self->$flush($timeout)->on_ready( sub {
            # The countdown may have started during the flush. Start it
            # again, so that the delay counts from the end of the flush.
            $timer->stop if $timer && $timer->loop;
            $self->$start_timer_if_idle;
        });
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
