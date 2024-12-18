use Object::Pad ':experimental(init_expr)';
# ABSTRACT: A LoggerProvider for the OpenTelemetry SDK

package OpenTelemetry::SDK::Logs::LoggerProvider;

our $VERSION = '0.014';

class OpenTelemetry::SDK::Logs::LoggerProvider
    :isa(OpenTelemetry::Logs::LoggerProvider)
{
    use Mutex;
    use OpenTelemetry::Common qw( timeout_timestamp maybe_timeout );
    use OpenTelemetry::Constants -export;
    use OpenTelemetry::SDK::InstrumentationScope;
    use OpenTelemetry::SDK::Logs::Logger;
    use OpenTelemetry::SDK::Logs::LogRecord;
    use OpenTelemetry::SDK::Resource;
    use OpenTelemetry::Trace;
    use Time::HiRes 'time';

    field $resource :param //= OpenTelemetry::SDK::Resource->new;
    field $stopped = 0;
    field %registry;
    field @processors;

    field $lock          //= Mutex->new;
    field $registry_lock //= Mutex->new;

    use Log::Any;
    my $logger = Log::Any->get_logger( category => 'OpenTelemetry' );

    method $create_log_record (%args) {
        return if $stopped;

        my %log = %args{qw(
            attributes
            body
            observed_timestamp
            resource
            instrumentation_scope
            severity_number
            severity_text
            timestamp
        )};

        $log{observed_timestamp} //= time;

        my $record = OpenTelemetry::SDK::Logs::LogRecord->new(
            %log,
            context => OpenTelemetry::Trace
                ->span_from_context( $args{context} )
                ->context,
        );

        $_->on_emit($record) for @processors;

        $record;
    }

    method logger (%args) {
        my %defaults;

        $defaults{instrumentation_scope} = do {
            # If no name is provided, we get it from the caller
            # This has to override the version, since the version
            # only makes sense for the name
            $args{name} || do {
                ( $args{name} ) = caller;
                $args{version}  = $args{name}->VERSION;
            };

            unless ( $args{name} ) {
                $logger->warn(
                    'Invalid name when retrieving tracer. Setting to empty string',
                    { value => $args{name} },
                );

                $args{name} //= '';
                delete $args{version};
            }

            OpenTelemetry::SDK::InstrumentationScope
                ->new( %args{qw( name version attributes )} );
        };

        $defaults{resource} = $args{schema_url}
            ? $resource->merge(
                OpenTelemetry::SDK::Resource->empty(
                    schema_url => $args{schema_url}
                ),
            )
            : $resource;

        $registry_lock->enter( sub {
            my $key
                = $defaults{instrumentation_scope}->to_string
                . '-'
                . $defaults{resource}->schema_url;

            $registry{$key} //= OpenTelemetry::SDK::Logs::Logger->new(
                callback => sub {
                    $self->$create_log_record( @_, %defaults );
                },
            );
        });
    }

    method $atomic_call_on_processors ( $method, $timeout ) {
        my $start = timeout_timestamp;

        my $result = EXPORT_RESULT_SUCCESS;

        for my $processor ( @processors ) {
            my $remaining = maybe_timeout $timeout, $start;

            if ( defined $remaining && $remaining == 0 ) {
                $result = EXPORT_RESULT_TIMEOUT;
                last;
            }

            my $res = $processor->$method($remaining);
            $result = $res if $res > $result;
        }

        return $result;
    }

    method shutdown ( $timeout = undef ) {
        if ( $stopped ) {
            $logger->warn('Attempted to shutdown a LoggerProvider more than once');
            return EXPORT_RESULT_FAILURE;
        }

        $lock->enter(
            sub {
                my $result = $self->$atomic_call_on_processors(
                    'shutdown',
                    $timeout
                );
                $stopped = 1;
                $result;
            }
        );
    }

    method force_flush ( $timeout = undef ) {
        return EXPORT_RESULT_SUCCESS if $stopped;

        $lock->enter(
            sub {
                $self->$atomic_call_on_processors( 'force_flush', $timeout );
            }
        );
    }

    method add_log_record_processor ($processor) {
        if ( $stopped ) {
            $logger->warn(
                'Attempted to add a log record processor to a LoggerProvider after shutdown'
            );
            return $self;
        }

        $lock->enter(
            sub { push @processors, $processor }
        );

        $self;
    }
}
