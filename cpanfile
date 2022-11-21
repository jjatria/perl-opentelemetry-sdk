requires 'Object::Pad', '0.57';
requires 'OpenTelemetry';
requires 'String::CRC32';
requires 'namespace::clean';

on test => sub {
    requires 'Test2::V0';
};
