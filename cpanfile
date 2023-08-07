requires 'Future', '0.26';             # Future->done
requires 'Future::AsyncAwait', '0.38'; # Object::Pad compatibility
requires 'Metrics::Any';
requires 'Mutex';
requires 'Object::Pad', '0.74'; # For //= field initialisers
requires 'OpenTelemetry';
requires 'Storable';
requires 'String::CRC32';
requires 'namespace::clean';

on test => sub {
    requires 'Test2::V0';
};
