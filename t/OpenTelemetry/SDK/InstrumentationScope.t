#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::InstrumentationScope';

use OpenTelemetry::Test::Logs;

is CLASS->new( name => 'foo' ), object {
    call to_string => '[foo:]';
}, 'Default version';

is CLASS->new( name => 'foo', version => '0.1' ), object {
    call to_string => '[foo:0.1]';
}, 'Explicit version';

is CLASS->new( name => 'foo', version => undef ), object {
    call to_string => '[foo:]';
}, 'Explicit undefined version';

OpenTelemetry::Test::Logs->clear;

is CLASS->new( name => undef ), object {
    call to_string => '[:]';
}, 'Explicit undefined name';

is + OpenTelemetry::Test::Logs->messages, [
    [
        warning => 'OpenTelemetry',
        'Created an instrumentation scope with an undefined name',
    ],
], 'Warned about undefined name';

like dies { CLASS->new },
    qr/Required parameter 'name' is missing/,
    'Name is required';

done_testing;
