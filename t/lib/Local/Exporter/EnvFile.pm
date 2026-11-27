package Local::Exporter::EnvFile;

# ABSTRACT: test exporter that appends summary lines to a file named by an env var
use Object::Pad ':experimental(init_expr)';

# A stand-in for the OTLP exporters, usable across forked processes: it
# appends a summary line per call to the file named by the
# OTEL_TEST_EXPORT_FILE environment variable, so the parent test process
# can read back what every process of the family exported. For export
# calls the line is `export <class-of-first-item> <count>`; the items are
# OpenTelemetry objects that cannot be JSON encoded, so only their class
# and count are recorded.
class Local::Exporter::EnvFile :does(OpenTelemetry::Exporter) {
    use Future::AsyncAwait;

    use feature 'say';

    field $path;
    field $done;

    ADJUST {
        $path = $ENV{OTEL_TEST_EXPORT_FILE}
            or die "OTEL_TEST_EXPORT_FILE environment variable is not set\n";
    }

    method _write ($line) {
        open my $handle, '>>', $path or die "cannot append to $path: $!\n";
        say $handle $line;
    }

    method export {
        my ( $items ) = @_;
        my $class = @$items ? ref $items->[0] : '';
        $self->_write( "export $class " . scalar( @$items ) );
        return 0;
    }

    async method force_flush {
        return 0 if $done;
        $self->_write( 'force_flush' );
        return 0;
    }

    async method shutdown {
        return 0 if $done;
        $done = 1;
        $self->_write( 'shutdown' );
        return 0;
    }
}

1;
