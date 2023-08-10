use Object::Pad ':experimental(init_expr)';
# ABSTRACT: A TracerProvider for the OpenTelemetry SDK

package OpenTelemetry::SDK::Trace::TracerProvider;

our $VERSION = '0.001';

use OpenTelemetry;

class OpenTelemetry::SDK::Trace::TracerProvider :isa(OpenTelemetry::Trace::TracerProvider) {
    use experimental 'try';

    use Future::AsyncAwait;
    use Future;
    use Mutex;

    use OpenTelemetry::Constants -trace_export;

    use OpenTelemetry::Common qw( timeout_timestamp maybe_timeout );
    use OpenTelemetry::Propagator::TraceContext::TraceFlags;
    use OpenTelemetry::SDK::InstrumentationScope;
    use OpenTelemetry::SDK::Resource;
    use OpenTelemetry::SDK::Trace::Sampler;
    use OpenTelemetry::SDK::Trace::Span;
    use OpenTelemetry::SDK::Trace::SpanLimits;
    use OpenTelemetry::SDK::Trace::Tracer;
    use OpenTelemetry::Trace::SpanContext;

    field $sampler      :param = undef;
    field $id_generator :param = 'OpenTelemetry::Trace';
    field $span_limits  :param //= OpenTelemetry::SDK::Trace::SpanLimits->new;
    field $resource     :param //= OpenTelemetry::SDK::Resource->new;
    field $stopped             = 0;
    field %registry;
    field @span_processors;

    field $lock          //= Mutex->new;
    field $registry_lock //= Mutex->new;

    ADJUST {
        return if $sampler;

        try {
            for ( $ENV{OTEL_TRACES_SAMPLER} // 'parentbased_always_on' ) {
                $sampler //= OpenTelemetry::SDK::Trace::Sampler::ALWAYS_ON  if $_ eq 'always_on';
                $sampler //= OpenTelemetry::SDK::Trace::Sampler::ALWAYS_OFF if $_ eq 'always_off';

                $sampler //= OpenTelemetry::SDK::Trace::Sampler->new(
                    TraceIDRatioBased => ( ratio => $ENV{OTEL_TRACES_SAMPLER_ARG} // 1 )
                ) if $_ eq 'traceidratio';

                $sampler //= OpenTelemetry::SDK::Trace::Sampler->new(
                    ParentBased => ( root => OpenTelemetry::SDK::Trace::Sampler::ALWAYS_ON )
                ) if $_ eq 'parentbased_always_on';

                $sampler //= OpenTelemetry::SDK::Trace::Sampler->new(
                    ParentBased => ( root => OpenTelemetry::SDK::Trace::Sampler::ALWAYS_OFF )
                ) if $_ eq 'parentbased_always_off';

                $sampler //= OpenTelemetry::SDK::Trace::Sampler->new(
                    ParentBased => (
                        root => OpenTelemetry::SDK::Trace::Sampler->new(
                            TraceIDRatioBased => ( ratio => $ENV{OTEL_TRACES_SAMPLER_ARG} // 1 )
                        ),
                    )
                ) if $_ eq 'parentbased_traceidratio';
            }
        }
        catch ($e) {
            my $default = OpenTelemetry::SDK::Trace::Sampler->new(
                ParentBased => ( root => OpenTelemetry::SDK::Trace::Sampler::ALWAYS_ON )
            );

            OpenTelemetry->handle_error(
                exception => $e,
                message   => 'installing default sampler ' . $default->description,
            );

            $sampler = $default;
        }
    }

    method $create_span (%args) {
        my %span = %args{qw( name kind start scope links )};

        $span{attribute_count_limit}  = $span_limits->attribute_count_limit;
        $span{attribute_length_limit} = $span_limits->attribute_length_limit;

        $span{parent} = OpenTelemetry::Trace
            ->span_from_context( $args{parent} )->context;

        my $trace_id = $span{parent}->valid
            ? $span{parent}->trace_id
            : $id_generator->generate_trace_id;

        my $result = $sampler->should_sample(
            trace_id   => $trace_id,
            context    => $args{parent},
            name       => $span{name},
            kind       => $span{kind},
            attributes => $args{attributes},
            links      => $span{links},
        );

        $span{attributes} = {
            %{ $args{attributes} // {} },
            %{ $result->attributes },
        };

        my $span_id = $id_generator->generate_span_id;

        if ( $result->recording && !$stopped ) {
            my $flags = $result->sampled
                ? OpenTelemetry::Propagator::TraceContext::TraceFlags->new(1)
                : OpenTelemetry::Propagator::TraceContext::TraceFlags->new(0);

            my $context = OpenTelemetry::Trace::SpanContext->new(
                trace_id    => $trace_id,
                span_id     => $span_id,
                trace_flags => $flags,
                trace_state => $result->trace_state,
            );

            $span{context}    = $context;
            $span{resource}   = $resource;
            $span{processors} = [ @span_processors ];

            return OpenTelemetry::SDK::Trace::Span->new(%span);
        }

        OpenTelemetry::Trace->non_recording_span(
            OpenTelemetry::Trace::SpanContext->new(
                trace_id    => $trace_id,
                span_id     => $span_id,
                trace_state => $result->trace_state,
            )
        );
    }

    method tracer ( %args ) {
        # If no name is provided, we get it from the caller
        # This has to override the version, since the version
        # only makes sense for the package
        $args{name} || do {
            ( $args{name} ) = caller;
            $args{version}  = $args{name}->VERSION;
        };

        OpenTelemetry->logger
            ->warnf('Got invalid tracer name when retrieving tracer: %s', $args{name})
            unless $args{name};

        my $scope = OpenTelemetry::SDK::InstrumentationScope
            ->new( %args{qw( name version )} );

        $registry_lock->enter( sub {
            $registry{ $scope->to_string } //= OpenTelemetry::SDK::Trace::Tracer->new(
                %args,
                span_creator => sub { $self->$create_span( @_, scope => $scope ) },
            );
        });
    }

    async method $atomic_call_on_processors ( $method, $timeout ) {
        my $start = timeout_timestamp;

        my $result = TRACE_EXPORT_SUCCESS;

        for my $processor ( @span_processors ) {
            my $remaining = maybe_timeout $timeout, $start;

            if ( defined $remaining && $remaining == 0 ) {
                $result = TRACE_EXPORT_TIMEOUT;
                last;
            }

            my $res = $processor->$method($remaining);
            $result = $res if $res > $result;
        }

        $stopped = 1;

        return $result;
    }

    method shutdown ( $timeout = undef ) {
        if ( $stopped ) {
            OpenTelemetry->logger->warn('Attempted to shutdown a TraceProvider more than once');
            return TRACE_EXPORT_FAILURE;
        }

        $lock->enter(
            sub {
                $self->$atomic_call_on_processors( 'shutdown', $timeout );
            }
        );
    }

    method force_flush ( $timeout = undef ) {
        return TRACE_EXPORT_SUCCESS if $stopped;

        $lock->enter(
            sub {
                $self->$atomic_call_on_processors( 'force_flush', $timeout );
            }
        );
    }

    method add_span_processor ($processor) {
        if ( $stopped ) {
            OpenTelemetry->logger->warn('Attempted to add a span processor to a TraceProvider after shutdown');
            return $self;
        }

        $lock->enter(
            sub {
                push @span_processors, $processor;
                Future->done;
            }
        );

        $self;
    }
}
