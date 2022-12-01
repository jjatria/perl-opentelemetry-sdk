#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::InstrumentationScope';

is CLASS->new( name => 'foo' ), object {
    call to_string => '[foo:]';
}, 'Default version';

is CLASS->new( name => 'foo', version => '0.1' ), object {
    call to_string => '[foo:0.1]';
}, 'Explicit version';

is CLASS->new( name => 'foo', version => undef ), object {
    call to_string => '[foo:]';
}, 'Explicit undefined version';

is CLASS->new( name => undef ), object {
    call to_string => '[:]';
}, 'Explicit undefined name';

like dies { CLASS->new },
    qr/Required parameter 'name' is missing/,
    'Name is required';

done_testing;
