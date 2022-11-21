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

    use namespace::clean -except => 'new';

    use OpenTelemetry::Trace::Event;
    use OpenTelemetry::Trace::Link;
    use OpenTelemetry::Trace::Span::Status;

    has $name       :param;
    has $parent     :param = undef;
    has $kind       :param = 'INTERNAL'; # TODO: representation?
    has $start      :param = undef;
    has $attributes :param = {};
    has $context    :reader;
    has $end;
    has @links;
    has @events;
    has $status;

    ADJUST ($params) {
        undef $start if $start && $start > time;
        $start //= utime;

        $kind = uc $kind;
        $kind = 'INTERNAL' unless $kind =~ /^ (:?
              INTERNAL
            | CONSUMER
            | PRODUCER
            | CLIENT
            | SERVER
        ) $/x;

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

    method set_attribute ( %attributes ) {
        unless ( $self->recording ) {
            $logger->warn('Attempted to set attributes on a span that is not recording');
            return $self
        }

        for my $pair ( pairs %attributes ) {
            my ( $key, $value ) = @$pair;

            if ( is_hashref $value ) {
                $logger->warnf('Span attribute values cannot be hash references');
                next;
            }

            if ( is_arrayref $value && any { ref } @$values ) {
                $logger->warnf('Span attribute values that are lists cannot hold references');
                next;
            }

            $key ||= do {
                $logger->warnf("Span attribute names should not be empty. Setting to 'null' instead");
                'null';
            };

            $attributes->{$key} = $value;
        }

        $self;
    }

    method set_status ( $status, $description = undef ) {
        return $self if ! $self->recording || $status->ok;

        my $new = OpenTelemetry::Trace::Span::Status->new(
            code        => $status,
            description => $description // '',
        );

        $status = $new unless $new->unset;

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
}
