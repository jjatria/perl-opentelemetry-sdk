#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Trace::Sampler::TraceIDRatioBased';

use OpenTelemetry::Trace;

is CLASS->new->description, 'TraceIDRatioBased{1.0}',
    'Sampler defaults to 1.0';

my ( $all, $almost_all, $most, $some, $few, $almost_none, $none )
    = map CLASS->new( ratio => $_ ), 1, 0.999999, .75, .5, .25,  0.000001, 0;

for (
    [ pack( 'H*', '0000000000000000ffffffffffffffff' ), T, F, F, F, F, F, F ],
    [ pack( 'H*', '0000000000000000ffffef39085f4a13' ), T, F, F, F, F, F, F ],
    [ pack( 'H*', '0000000000000000ffffef39085f4a12' ), T, T, F, F, F, F, F ],
    [ pack( 'H*', '0000000000000000aaaaaaaaaaaaaaaa' ), T, T, T, F, F, F, F ],
    [ pack( 'H*', '00000000000000005555555555555555' ), T, T, T, T, F, F, F ],
    [ pack( 'H*', '0000000000000000000010c6f7a0b5ee' ), T, T, T, T, T, F, F ],
    [ pack( 'H*', '0000000000000000000010c6f7a0b5ed' ), T, T, T, T, T, T, F ],
    [ pack( 'H*', '00000000000000000000000000000000' ), T, T, T, T, T, T, F ],
) {
    my ( $id, @want ) = @$_;

    subtest sprintf( 'With ID %s', unpack 'H*', $id ) => sub {
        is $all->should_sample( trace_id => $id ), object {
            call recording => $want[0];
        }, 'Sample all';

        is $almost_all->should_sample( trace_id => $id ), object {
            call recording => $want[1];
        }, 'Sample almost all';

        is $most->should_sample( trace_id => $id ), object {
            call recording => $want[2];
        }, 'Sample most';

        is $some->should_sample( trace_id => $id ), object {
            call recording => $want[3];
        }, 'Sample some';

        is $few->should_sample( trace_id => $id ), object {
            call recording => $want[4];
        }, 'Sample a few';

        is $almost_none->should_sample( trace_id => $id ), object {
            call recording => $want[5];
        }, 'Almost never sample';

        is $none->should_sample( trace_id => $id ), object {
            call recording => $want[6];
        }, 'Never sample';
    };
}

done_testing;
