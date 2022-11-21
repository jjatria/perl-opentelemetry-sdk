#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Trace::Sampler::TraceIDRatioBased';

use OpenTelemetry::Trace;

is CLASS->new->description, 'TraceIDRatioBased{1.0}',
    'Sampler defaults to 1.0';

my ( $all, $most, $some, $few, $none )
    = map CLASS->new( ratio => $_ ), 1, .75, .5, .25,  0;

for (
    [ pack( 'H*', 'a406c68a98eee445b6b6dc65ab0dab4e' ), 0.96, 1, 0, 0, 0, 0 ],
    [ pack( 'H*', '910638ea0e3d867287ebdce025679134' ), 0.69, 1, 1, 0, 0, 0 ],
    [ pack( 'H*', '1500e7f19819e79bfa49d23c80e811aa' ), 0.32, 1, 1, 1, 0, 0 ],
    [ pack( 'H*', '36258adf4cb55244e35d7f74a44d564d' ), 0.10, 1, 1, 1, 1, 0 ],
) {
    my ( $id, $ratio, @want ) = @$_;

    subtest $ratio => sub {
        is $all->should_sample( trace_id => $id ), object {
            call recording => $want[0] ? T : F;
        }, 'all';

        is $most->should_sample( trace_id => $id ), object {
            call recording => $want[1] ? T : F;
        }, 'most';

        is $some->should_sample( trace_id => $id ), object {
            call recording => $want[2] ? T : F;
        }, 'some';

        is $few->should_sample( trace_id => $id ), object {
            call recording => $want[3] ? T : F;
        }, 'few';

        is $none->should_sample( trace_id => $id ), object {
            call recording => $want[4] ? T : F;
        }, 'none';
    };
}

done_testing;
