use v5.26;
use Object::Pad;

use feature 'isa';

package OpenTelemetry::SDK::Trace::Span;

our $VERSION = '0.001';

use OpenTelemetry;
my $logger = OpenTelemetry->logger;

class OpenTelemetry::SDK::Trace::Span :isa(OpenTelemetry::Trace::Span) {
    use Time::HiRes 'time';
    use Ref::Util qw( is_arrayref is_hashref );
    use List::Util qw( any pairs );

    use OpenTelemetry::Common 'validate_attribute_value';

    use namespace::clean -except => 'new';

    use OpenTelemetry::Trace;
    use OpenTelemetry::Trace::Event;
    use OpenTelemetry::Trace::Link;
    use OpenTelemetry::Trace::Span::Status;
    use OpenTelemetry::SDK::Trace::Span::Snapshot;

    has $name       :param;
    has $parent     :param = undef;
    has $kind       :param = 'INTERNAL'; # TODO: representation?
    has $start      :param = undef;
    has $end;
    has $status;
    has %attributes;
    has @links;
    has @events;

    ADJUST ($params) {
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

        for my $link ( @{ delete $params->{links} // [] } ) {
            $link isa OpenTelemetry::Trace::Link
                ? push( @links, $link )
                : $self->add_link(%$link);
        }

        $self->set_attribute( %{ delete $params->{attributes} // {} } );
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

    method finish ( $time = undef ) {
        return $self unless $self->recording;

        $end = $time // time;

        $self;
    }

    method recording () { ! defined $end }

    method snapshot () {
        my $parent_span_id = OpenTelemetry::Trace->span_from_context($parent)->context->span_id;
        my $context = $self->context;

        OpenTelemetry::SDK::Trace::Span::Snapshot->new(
            name                      => $name,
            kind                      => $kind,
            status                    => $status,
            parent_span_id            => $parent_span_id,
            total_recorded_attributes => scalar keys %attributes,
            total_recorded_events     => scalar @events,
            total_recorded_links      => scalar @links,
            start_timestamp           => $start,
            end_timestamp             => $end,
            attributes                => { %attributes },
            links                     => [ @links ],
            events                    => [ @events ],
            resource                  => 1, # ...,
            instrumentation_scope     => 1, # ...,
            span_id                   => $context->span_id,
            trace_id                  => $context->trace_id,
            trace_flags               => $context->trace_flags->flags,
            trace_state               => $context->trace_state,
        );
    }
}
