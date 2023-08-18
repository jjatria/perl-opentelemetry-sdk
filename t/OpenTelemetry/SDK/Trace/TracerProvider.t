#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Trace::TracerProvider';
use Test2::Tools::OpenTelemetry;

use OpenTelemetry::SDK::InstrumentationScope;

my $provider = CLASS->new;

subtest Tracer => sub {
    no_messages {
        is my $default = $provider->tracer, object {
            prop isa => 'OpenTelemetry::SDK::Trace::Tracer';
        }, 'Can get tracer with no arguments';

        is my $specific = $provider->tracer( name => 'foo', version => 123 ),
            object { prop isa => 'OpenTelemetry::SDK::Trace::Tracer';
        }, 'Can get tracer with name and version';

        my $scope = OpenTelemetry::SDK::InstrumentationScope->new(
            name    => 'foo',
            version => 123,
        );

        ref_is $provider->tracer($scope), $specific,
            'Can get tracer with scope and it is cached';
    };
};

done_testing;
