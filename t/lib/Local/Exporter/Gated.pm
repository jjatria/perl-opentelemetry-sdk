use Object::Pad;

# An exporter that records when each export starts, and then waits until
# the test releases it. The test can release every export, or only the
# export whose first record has a given id. If the first record has a
# result, the export returns it. Exports run in worker processes, so the
# records and the release go through files.
class Local::Exporter::Gated :does(OpenTelemetry::Exporter) {
    use File::Temp 'tempdir';
    use Future::AsyncAwait;
    use JSON::PP;
    use Time::HiRes ();

    field $result :param = 0;
    field $dir = tempdir( CLEANUP => 1 );

    method $log ( @args ) {
        open my $handle, '>>', "$dir/events" or die $!;
        print $handle encode_json( [ @args ] ), "\n";
    }

    method events {
        open my $handle, '<', "$dir/events" or return [];
        [ map { decode_json $_ } <$handle> ];
    }

    method started { scalar grep { $_->[0] eq 'start' } $self->events->@* }

    method release ( $id = undef ) {
        my $file = defined $id ? "$dir/release.$id" : "$dir/release";
        open my $handle, '>', $file or die $!;
    }

    method export ( $batch, @ ) {
        $self->$log( start => scalar @$batch );

        my $first = ref $batch->[0] eq 'HASH' ? $batch->[0] : {};
        my $id    = $first->{id};
        my $released = sub {
            -e "$dir/release" || ( defined $id && -e "$dir/release.$id" );
        };

        my $deadline = Time::HiRes::time + 10;
        Time::HiRes::sleep 0.005
            until $released->() || Time::HiRes::time > $deadline;

        die "The test did not release the exporter\n" unless $released->();

        $self->$log( end => scalar @$batch );
        return $first->{result} // $result;
    }

    async method force_flush { 0 }
    async method shutdown    { 0 }
}
