use Object::Pad;

# An exporter whose export number C<$fail_number> fails: that one call
# returns a failure result, every other one behaves like the file
# exporter. Only the export child ever calls export, so the count is not
# split over processes.
class Local::Exporter::Failing :isa(Local::Exporter::File) {
    use Local::Exporter::File;
    use OpenTelemetry::Constants '-export';

    field $fail_number :param = 1;
    field $exports     = 0;

    method export ( $batch, $timeout ) {
        my $result = $self->SUPER::export( $batch, $timeout );

        return ++$exports == $fail_number
            ? EXPORT_RESULT_FAILURE
            : $result;
    }
}

1;
