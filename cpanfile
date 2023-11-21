requires 'Feature::Compat::Try';
requires 'Future::AsyncAwait', '0.38'; # Object::Pad compatibility
requires 'IO::Async::Loop';
requires 'Metrics::Any';
requires 'Mutex';
requires 'Object::Pad', '0.74'; # For //= field initialisers
requires 'OpenTelemetry', '0.010';

recommends 'OpenTelemetry::Exporter::OTLP';

on test => sub {
    requires 'File::Temp';
    requires 'JSON::PP';
    requires 'Syntax::Keyword::Dynamically';
    requires 'Test2::V0';
};
