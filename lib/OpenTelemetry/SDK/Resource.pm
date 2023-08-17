use Object::Pad ':experimental(init_expr)';

package OpenTelemetry::SDK::Resource;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Resource :does(OpenTelemetry::Attributes) {
    use experimental 'isa';

    use OpenTelemetry;
    use OpenTelemetry::Common 'config';
    use File::Basename 'basename';

    require OpenTelemetry::SDK; # For VERSION

    field $schema_url :param :reader //= '';

    sub BUILDARGS ( $class, %args ) {
        my %env = map split( '=', $_, 2 ),
            split ',', config('RESOURCE_ATTRIBUTES') // '';

        $args{attributes} = {
            # TODO: Should these be split / moved somewhere else?
            # How are they overidden?
            'service.name'            => config('SERVICE_NAME') // 'unknown_service',
            'telemetry.sdk.name'      => 'opentelemetry',
            'telemetry.sdk.language'  => 'perl',
            'telemetry.sdk.version'   => $OpenTelemetry::SDK::VERSION,
            'process.pid'             => $$,
            'process.command'         => $0,
            'process.executable.path' => $^X,
            'process.command_args'    => [ @ARGV ],
            'process.executable.name' => basename($^X),
            'process.runtime.name'    => 'perl',
            'process.runtime.version' => "$^V",

            %env,

            %{ $args{attributes} // {} },
        };

        %args;
    }

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
