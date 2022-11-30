use Object::Pad;
# ABSTRACT: A TracerProvider for the OpenTelemetry SDK

package OpenTelemetry::SDK::Trace::TracerProvider;

our $VERSION = '0.001';

use OpenTelemetry;

# TODO: Move somewhere shared
use constant {
    EXPORT_SUCCESS => 0,
    EXPORT_FAILURE => 1,
    EXPORT_TIMEOUT => 2,
};

class OpenTelemetry::SDK::Trace::TracerProvider :isa(OpenTelemetry::Trace::TracerProvider) {
    use experimental 'try';

    use OpenTelemetry::Trace::SpanContext;
    use OpenTelemetry::SDK::Resource;
    use OpenTelemetry::SDK::Trace::Sampler;
    use OpenTelemetry::SDK::Trace::Tracer;
    use OpenTelemetry::SDK::Trace::SpanLimits;
    use OpenTelemetry::Common qw(
        timeout_timestamp
        maybe_timeout
    );

    use namespace::clean -except => 'new';

    has $sampler      :param = undef;
    has $id_generator :param = 'OpenTelemetry::Trace';
    has $span_limits  :param = undef;
    has $resource     :param = undef;
    has $stopped             = 0;
    has %tracer_registry;
    has @span_processors;

    ADJUST {
        $resource  //= OpenTelemetry::SDK::Resource->new;
        $span_limits = OpenTelemetry::SDK::Trace::SpanLimits->new;

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
            ) if $_ eq 'parentbased_always_on';

            OpenTelemetry->handle_error(
                exception => $e,
                message   => 'installing default sampler ' . $default->description,
            );

            $sampler = $default;
        }
    }

    method $create_span (%args) {
        my %span = %args{qw( name parent kind start )};

        {
            my $parent = OpenTelemetry::Trace
                ->span_from_context( $args{parent} )->context;

            if ( $parent->valid ) {
                $span{parent_span_id} = $parent->span_id;
                $span{trace_id}       = $parent->trace_id;
            }
        }

        $span{trace_id} //= $id_generator->generate_trace_id;
        $span{span_id}    = $id_generator->generate_span_id;
        $span{resource}   = $resource;

        my $result = $sampler->should_sample(
            trace_id   => $span{trace_id},
            context    => $args{parent},
            name       => $args{name},
            kind       => $args{kind},
            attributes => $args{attributes},
            links      => $args{links},
        );

        $span{attributes} = { %{ $args{attributes} // {} }, %{ $result->attributes } };

        return OpenTelemetry::SDK::Trace::Span->new(%span)
            if $result->recording && !$stopped;

        OpenTelemetry::Trace->non_recording_span(
            OpenTelemetry::Trace::SpanContext->new(
                trace_id    => $span{trace_id},
                span_id     => $span{span_id},
                trace_state => $result->trace_state,
            )
        );
    }

    method tracer ( %args ) {
        OpenTelemetry->logger->warnf('Got invalid tracer name when retrieving tracer: %s', $args{name})
            unless $args{name};

        $args{name}    //= '';
        $args{version} //= '';

        # TODO: lock?
        $tracer_registry{ join ':', @args{qw( name version )} } //= OpenTelemetry::SDK::Trace::Tracer->new(
            %args,
            span_creator => sub { $self->$create_span(@_) },
        );
    }

    method shutdown ( $timeout = undef ) {
        # TODO: lock?

        if ( $stopped ) {
            OpenTelemetry->logger->warn('Attempted to shutdown a TraceProvider more than once');
            return EXPORT_FAILURE;
        }

        my $start = timeout_timestamp;

        my $result = EXPORT_SUCCESS;

        for my $processor ( @span_processors ) {
            my $remaining = maybe_timeout $timeout, $start;

            if ( defined $remaining && $remaining == 0 ) {
                $result = EXPORT_TIMEOUT;
                last;
            }

            my $res = $processor->shutdown($remaining);
            $result = $res if $res > $result;
        }

        $stopped = 1;

        return $result;
    }

    method add_span_processor ($processor) {
        # TODO: lock?

        if ( $stopped ) {
            OpenTelemetry->logger->warn('Attempted to add a span processor to a TraceProvider after shutdown');
            return;
        }

        push @span_processors, $processor;

        $self;
    }
}
