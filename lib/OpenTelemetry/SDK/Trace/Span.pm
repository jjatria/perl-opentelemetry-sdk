use Object::Pad ':experimental(init_expr)';

package OpenTelemetry::SDK::Trace::Span;

our $VERSION = '0.001';

use OpenTelemetry;
my $logger = OpenTelemetry->logger;

class OpenTelemetry::SDK::Trace::Span
    :isa(OpenTelemetry::Trace::Span)
    :does(OpenTelemetry::Attributes)
{
    use experimental 'isa';

    use List::Util qw( any pairs );
    use Mutex;
    use Ref::Util qw( is_arrayref is_hashref );
    use Time::HiRes 'time';

    use OpenTelemetry::Constants
        -span_kind => { -as => sub { shift =~ s/^SPAN_KIND_//r } };

    use OpenTelemetry::SDK::Trace::SpanLimits;
    use OpenTelemetry::SDK::Trace::Span::Readable;
    use OpenTelemetry::Trace::Event;
    use OpenTelemetry::Trace::Link;
    use OpenTelemetry::Trace::SpanContext;
    use OpenTelemetry::Trace::Span::Status;
    use OpenTelemetry::Trace;

    field $dropped_events      = 0;
    field $dropped_links       = 0;
    field $end;
    field $kind       :param   = INTERNAL;
    field $limits     :param //= OpenTelemetry::SDK::Trace::SpanLimits->new;
    field $lock                = Mutex->new;
    field $name       :param;
    field $parent     :param   = OpenTelemetry::Trace::SpanContext::INVALID;
    field $resource   :param   = undef;
    field $scope      :param;
    field $start      :param   = undef;
    field $status              = OpenTelemetry::Trace::Span::Status->unset;
    field @events;
    field @links;
    field @processors;

    ADJUSTPARAMS ( $params ) {
        my $now = time;
        undef $start if $start && $start > $now;
        $start //= $now;

        $kind = INTERNAL if $kind < INTERNAL || $kind > CONSUMER;

        @processors = @{ delete $params->{processors} // [] };

        for my $link ( @{ delete $params->{links} // [] } ) {
            $link isa OpenTelemetry::Trace::Link
                ? push( @links, $link )
                : $self->add_link(%$link);
        }
    }

    method set_name ( $new ) {
        return $self unless $self->recording && $new;

        $name = $new;

        $self;
    }

    method set_attribute ( %new ) {
        unless ( $self->recording ) {
            $logger->warn('Attempted to set attributes on a span that is not recording');
            return $self
        }

        # FIXME: Ideally an overridable method from role, but that is not supported
        $self->_set_attribute( %new );
    }

    method set_status ( $new, $description = undef ) {
        return $self if !$self->recording || $status->is_ok;

        my $value = OpenTelemetry::Trace::Span::Status->new(
            code        => $new,
            description => $description // '',
        );

        $status = $value unless $value->is_unset;

        $self;
    }

    method add_link ( %args ) {
        return $self unless $self->recording
            && $args{context} isa OpenTelemetry::Trace::SpanContext;

        if ( scalar @links >= $limits->link_count_limit ) {
            $dropped_links++;
            $logger->warn('Dropped link because it would exceed specified limit');
            return $self;
        }

        push @links, OpenTelemetry::Trace::Link->new(
            context                => $args{context},
            attributes             => $args{attributes},
            attribute_count_limit  => $limits->link_attribute_count_limit,
            attribute_length_limit => $limits->link_attribute_length_limit,
        );

        $self;
    }

    method add_event (%args) {
        return $self unless $self->recording;

        if ( scalar @events >= $limits->event_count_limit ) {
            $dropped_events++;
            $logger->warn('Dropped event because it would exceed specified limit');
            return $self;
        }

        push @events, OpenTelemetry::Trace::Event->new(
            name                   => $args{name},
            timestamp              => $args{timestamp},
            attributes             => $args{attributes},
            attribute_count_limit  => $limits->event_attribute_count_limit,
            attribute_length_limit => $limits->event_attribute_length_limit,
        );

        $self;
    }

    method end ( $time = undef ) {
        return $self unless $lock->enter( sub {
            unless ($self->recording) {
                $logger->warn('Calling end on an ended Span');
                return;
            }

            $end = $time // time;
        });

        $_->on_end($self) for @processors;

        $self;
    }

    method record_exception ( $exception, %attributes ) {
        $self->add_event(
            name       => 'exception',
            attributes => {
                'exception.type'       => ref $exception || '',
                'exception.message'    => "$exception" =~ s/\n.*//r,
                'exception.stacktrace' => "$exception",
                %attributes,
            }
        );
    }

    method recording () { ! defined $end }

    method snapshot () {
        OpenTelemetry::SDK::Trace::Span::Readable->new(
            attributes            => $self->attributes,
            context               => $self->context,
            dropped_events        => $dropped_events,
            dropped_links         => $dropped_links,
            end_timestamp         => $end,
            events                => [ @events ],
            instrumentation_scope => $scope,
            kind                  => $kind,
            links                 => [ @links ],
            name                  => $name,
            parent_span_id        => $parent->span_id,
            resource              => $resource,
            start_timestamp       => $start,
            status                => $status,
        );
    }
}
