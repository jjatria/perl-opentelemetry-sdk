#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Resource';

require OpenTelemetry::SDK;

local %ENV;

my %default = (
    'service.name'            => 'unknown_service',
    'telemetry.sdk.name'      => 'opentelemetry',
    'telemetry.sdk.language'  => 'perl',
    'telemetry.sdk.version'   => $OpenTelemetry::SDK::VERSION,
    'process.pid'             => $$,
    'process.command'         => $0,
    'process.executable.path' => $^X,
    'process.command_args'    => T,
    'process.executable.name' => T,
    'process.runtime.name'    => 'perl',
    'process.runtime.version' => "$^V",
);

subtest New => sub {
    is CLASS->new( schema_url => 'foo', attributes => { key => 'value' } ), object {
        call schema_url => 'foo';
        call attributes => { key => 'value', %default };
    }, 'Arguments to constructor';

    subtest 'Empty environment' => sub {
        is CLASS->new, object {
            call schema_url => '';
            call attributes => \%default;
        }, 'Only default attributes';
    };

    subtest 'Empty environment' => sub {
        local %ENV = (
            OTEL_RESOURCE_ATTRIBUTES => 'key1=value1,key2=value2',
            OTEL_SERVICE_NAME        => 'some_service',
        );

        is CLASS->new, object {
            call schema_url => '';
            call attributes => {
                %default,
                'key1'         => 'value1',
                'key2'         => 'value2',
                'service.name' => 'some_service',
            };
        }, 'Attributes from environment';
    };
};

subtest 'Attributes are not mutable' => sub {
    my $new = CLASS->new( attributes => { ref => [ 1 ] } );
    my $data = $new->attributes;
    push @{ $data->{ref} }, 'test';

    is $new, object {
        call attributes => { %default, ref => [ 1 ] };
    }, 'Did not change';
};

subtest 'Merge' => sub {
    my $foo = CLASS->new( schema_url => 'foo', attributes => { a => 1, b => 1 } );
    my $bar = CLASS->new( schema_url => 'bar', attributes => { b => 2, c => 2 } );
    my $non = CLASS->new;

    is $foo->merge($bar), object {
        call schema_url => 'foo';
        call attributes => { %default, a => 1, b => 2, c => 2 };
    }, 'Prefer new but keep schema URL when mismatched';

    is $bar->merge($foo), object {
        call schema_url => 'bar';
        call attributes => { %default, a => 1, b => 1, c => 2 };
    }, 'Confirm preference';

    is $non->merge($foo), object {
        call schema_url => 'foo';
        call attributes => { %default, a => 1, b => 1 };
    }, 'No schema URL is updated';

    is $foo->merge($non), object {
        call schema_url => 'foo';
        call attributes => { %default, a => 1, b => 1 };
    }, 'Existing schema URL stays if new is unset';
};

done_testing;
