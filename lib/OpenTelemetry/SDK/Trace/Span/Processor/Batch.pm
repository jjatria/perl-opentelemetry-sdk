use Object::Pad ':experimental(init_expr)';
# ABSTRACT: A batched OpenTelemetry span processor

package OpenTelemetry::SDK::Trace::Span::Processor::Batch;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Trace::Span::Processor::Batch :does(OpenTelemetry::SDK::Trace::Span::Processor) {
    use IO::Async::Loop;
    use IO::Async::Function;
    use OpenTelemetry;
    use OpenTelemetry::Common 'config';
    use OpenTelemetry::Constants -trace_export;
    use Future::AsyncAwait;
    use Mutex;

    use Metrics::Any '$metrics', strict => 0;
    my $logger = OpenTelemetry->logger;

    use namespace::clean -except => 'new';

    field $batch_size       :param //= config('BSP_MAX_EXPORT_BATCH_SIZE') //    512;
    field $exporter_timeout :param //= config('BSP_EXPORT_TIMEOUT')        // 30_000;
    field $max_queue_size   :param //= config('BSP_MAX_QUEUE_SIZE')        //  2_048;
    field $schedule_delay   :param //= config('BSP_SCHEDULE_DELAY')        //  5_000;

    field $exporter         :param;
    field $function;
    field $lock                    = Mutex->new;
    field @futures;
    field @queue;

    ADJUST {
        if ( $batch_size > $max_queue_size ) {
            OpenTelemetry->logger->warnf(
                'Max export batch size (%s) was greater than maximum queue size (%s) when instantiating batch processor',
                $batch_size,
                $max_queue_size,
            );
            $batch_size = $max_queue_size;
        }

        $function = IO::Async::Function->new(
            code => sub ( $exporter, $batch, $timeout ) {
                $exporter->export( $batch, $timeout )->get;
            },
        );

        IO::Async::Loop->new->add($function);

        $function->start if config('BSP_START_THREAD_ON_BOOT') // 1;
    }

    method $report_dropped_spans ( $count, $reason ) {
        $metrics->inc_counter_by(
            'otel.bsp.dropped_spans' => $count, { reason => $reason },
        );
    }

    method $report_result ( $code, $batch ) {
        my $count = @$batch;

        if ( $code == TRACE_EXPORT_SUCCESS ) {
            $metrics->inc_counter('otel.bsp.export.success');
            $metrics->inc_counter_by( 'otel.bsp.exported_spans' => $count );
            return;
        }

        OpenTelemetry->handle_error(
            exception => sprintf(
                'Unable to export %s span%s', $count, $count ? 's' : ''
            ),
        );

        $metrics->inc_counter('otel.bsp.export.failure');
        $self->$report_dropped_spans( $count, 'export-failure' );
    }

    method $maybe_process_batch ( $force = undef ) {
        my $batch = $lock->enter(
            sub {
                return [] if @queue < $batch_size && !$force;

                $metrics->set_gauge_to(
                    'otel.bsp.buffer_utilization' => @queue / $max_queue_size,
                ) if @queue;

                [ map $_->snapshot, splice @queue, 0, $batch_size ];
            }
        );

        return unless @$batch;

        $function->call(
            args => [ $exporter, $batch, $exporter_timeout ],
            on_result => sub ( $type, $result ) {
                return $self->$report_result( TRACE_EXPORT_FAILURE, $batch )
                    unless $type eq 'return';

                $self->$report_result( $result, $batch );
            },
        );

        return;
    }

    # TODO: validate exporter?

    method on_start ( $span, $context ) { }

    method on_end ($span) {
        return unless $span->context->trace_flags->sampled;

        $lock->enter( sub { push @queue, $span } );
        $self->$maybe_process_batch;

        return;
    }

    async method shutdown ( $timeout = undef ) { ... }

    async method force_flush ( $timeout = undef ) { ... }
}
