#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Trace::Sampler';
use Test2::Tools::OpenTelemetry;

is CLASS->ALWAYS_OFF, object {
    prop isa => 'OpenTelemetry::SDK::Trace::Sampler::Constant';
    call description => 'AlwaysOffSampler';
    call should_sample => object {
        call sampled     => F;
        call recording   => F;
    };
}, 'ALWAYS_OFF is neither sampled or recording';

is CLASS->ALWAYS_ON, object {
    prop isa => 'OpenTelemetry::SDK::Trace::Sampler::Constant';
    call description => 'AlwaysOnSampler';
    call should_sample => object {
        call sampled     => T;
        call recording   => T;
    };
}, 'ALWAYS_ON is sampled and recording';

subtest Constructor => sub {
    no_messages {
        is CLASS->new( ParentBased => ( root => mock ) ), object {
            prop isa => 'OpenTelemetry::SDK::Trace::Sampler::ParentBased';
        }, 'Can create other samplers';
    };

    is messages {
        is CLASS->new( FakeSampler => ( root => mock ) ), object {
            prop isa         => 'OpenTelemetry::SDK::Trace::Sampler::Constant';
            call description => 'AlwaysOffSampler';
        }, 'Falls back to ALWAYS_OFF';
    } => [
        [
            warning => 'OpenTelemetry',
            match qr/^Cannot create FakeSampler sampler: /
        ],
    ], 'Unknown sampler is logged';
};

done_testing;
