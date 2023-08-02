use Object::Pad ':experimental(init_expr)';

package OpenTelemetry::SDK::Resource;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Resource {
    use experimental 'isa';

    use OpenTelemetry;
    use OpenTelemetry::Common qw( config validate_attribute_value );

    use Storable 'dclone';

    use namespace::clean -except => 'new';

    field $attributes :param         //= {};
    field $schema_url :param :reader //= '';

    ADJUSTPARAMS ( $params ) {
        my %new = map split( '=', $_, 2 ),
            split ',', config('RESOURCE_ATTRIBUTES') // '';

        %new = ( %new, %{ delete $params->{attributes} // {} } );

        my $logger = OpenTelemetry->logger;
        for my $key ( keys %new ) {
            my $value = $new{$key};
            next unless validate_attribute_value $value;

            $key ||= do {
                $logger->warnf("Resource attribute names should not be empty. Setting to 'null' instead");
                'null';
            };

            $attributes->{$key} = $value;
        }
    }

    method attributes () { dclone $attributes }

    method merge ( $new ) {
        return $self unless $new isa OpenTelemetry::SDK::Resource;

        my $ours   = $self->schema_url;
        my $theirs = $new->schema_url;

        if ( $ours && $theirs && $ours ne $theirs ) {
            OpenTelemetry->logger->warnf("Incompatible resource schema URLs in call to merge. Keeping existing one: '%s'", $ours);
            $theirs = '';
        }

        ( ref $self )->new(
            attributes => { %{ $self->attributes }, %{ $new->attributes } },
            schema_url => $theirs || $ours,
        );
    }
}
