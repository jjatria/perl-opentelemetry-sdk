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

     ADJUSTPARAMS ( $params ) {
         my %new = map split( '=', $_, 2 ),
             split ',', config('RESOURCE_ATTRIBUTES') // '';

         # TODO: Should these be split / moved somewhere else?
         # How are they overidden?
         $new{'service.name'}            = config('SERVICE_NAME') // 'unknown_service';
         $new{'telemetry.sdk.name'}      = 'opentelemetry';
         $new{'telemetry.sdk.language'}  = 'perl';
         $new{'telemetry.sdk.version'}   = $OpenTelemetry::SDK::VERSION;
         $new{'process.pid'}             = $$;
         $new{'process.command'}         = $0;
         $new{'process.executable.path'} = $^X;
         $new{'process.command_args'}    = [ @ARGV ],
         $new{'process.executable.name'} = basename $^X;
         $new{'process.runtime.name'}    = 'perl';
         $new{'process.runtime.version'} = "$^V";

        $self->_set_attribute(%new);
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
