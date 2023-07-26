use v5.26;
use Object::Pad;

use feature 'isa';

package OpenTelemetry::SDK::Trace::Span;

our $VERSION = '0.001';

use OpenTelemetry;
my $logger = OpenTelemetry->logger;

class OpenTelemetry::SDK::Trace::Span :isa(OpenTelemetry::Trace::Span) {
    use List::Util qw( any pairs );
    use Mutex;
    use Ref::Util qw( is_arrayref is_hashref );
    use Time::HiRes 'time';

    use OpenTelemetry::Common 'validate_attribute_value';

    use namespace::clean -except => 'new';

    use OpenTelemetry::Trace;
    use OpenTelemetry::Trace::Event;
    use OpenTelemetry::Trace::Link;
    use OpenTelemetry::Trace::Span::Status;

    has $end;
    has $kind       :param = 'INTERNAL'; # TODO: representation?
    has $lock;
    has $name       :param;
    has $parent     :param = undef;
    has $resource   :param = undef;
    has $scope      :param;
    has $start      :param = undef;
    has $status;
    has %attributes;
    has @events;
    has @links;
    has @processors;

    ADJUSTPARAMS ( $params ) {
        undef $start if $start && $start > time;
        $start //= time;

        $kind = uc $kind;
        $kind = 'INTERNAL' unless $kind =~ /^ (:?
              INTERNAL
            | CONSUMER
            | PRODUCER
            | CLIENT
            | SERVER
        ) $/x;

        $status = OpenTelemetry::Trace::Span::Status->new;

        @processors = @{ delete $params->{processors} // [] };

        for my $link ( @{ delete $params->{links} // [] } ) {
            $link isa OpenTelemetry::Trace::Link
                ? push( @links, $link )
                : $self->add_link(%$link);
        }

        $self->set_attribute( %{ delete $params->{attributes} // {} } );

        $lock = Mutex->new;
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

        for my $pair ( pairs %new ) {
            my ( $key, $value ) = @$pair;

            next unless validate_attribute_value $value;

            $key ||= do {
                $logger->warnf("Span attribute names should not be empty. Setting to 'null' instead");
                'null';
            };

            $attributes{$key} = $value;
        }

        $self;
    }

    method set_status ( $new, $description = undef ) {
        return $self if !$self->recording || $status->ok;

        my $value = OpenTelemetry::Trace::Span::Status->new(
            code        => $new,
            description => $description // '',
        );

        $status = $value unless $value->unset;

        $self;
    }

    method add_link ( %args ) {
        return $self unless $self->recording
            && $args{context} isa OpenTelemetry::Trace::SpanContext;

        push @links, OpenTelemetry::Trace::Link->new(
            context    => $args{context},
            attributes => $args{attributes},
        );

        $self;
    }

    method add_event (%args) {
        return $self unless $self->recording;

        push @events, OpenTelementry::Trace::Event->new(
            name       => $args{name},
            timestamp  => $args{timestamp},
            attributes => $args{attributes},
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

    method recording () { ! defined $end }

    method snapshot () {
        my $context = $self->context;

        my %snapshot = (
            attributes                => { %attributes },
            end_timestamp             => $end,
            events                    => [ @events ],
            instrumentation_scope     => $scope->to_string,
            kind                      => $kind,
            links                     => [ @links ],
            name                      => $name,
            span_id                   => $context->hex_span_id,
            start_timestamp           => $start,
            status                    => $status->to_string,
            total_recorded_attributes => scalar keys %attributes,
            total_recorded_events     => scalar @events,
            total_recorded_links      => scalar @links,
            trace_flags               => $context->trace_flags->flags,
            trace_id                  => $context->hex_trace_id,
            trace_state               => $context->trace_state->to_string,
        );

        $snapshot{resource} = $resource ? $resource->attributes : {};

        my $span_context = OpenTelemetry::Trace
            ->span_from_context($parent)
            ->context;

        $snapshot{parent_span_id} = $span_context->hex_span_id
            if $span_context->valid;

        \%snapshot;
    }
}
