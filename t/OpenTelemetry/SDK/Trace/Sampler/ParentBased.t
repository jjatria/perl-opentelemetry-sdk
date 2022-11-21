#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Trace::Sampler::ParentBased';

use OpenTelemetry::Context;
use OpenTelemetry::Trace;

is CLASS->new( root => mock(obj => add => [ description => 'RootSampler' ]) )
    ->description,
    'ParentBased{root=RootSampler,remote_parent_sampled=AlwaysOnSampler,remote_parent_not_sampled=AlwaysOffSampler,local_parent_sampled=AlwaysOnSampler,local_parent_not_sampled=AlwaysOffSampler}',
    'Composite description';

my %samplers = map {
    my $name = $_;
    $name => mock obj => add => [ should_sample => sub { $name } ];
} qw(
    root
    remote_parent_sampled
    remote_parent_not_sampled
    local_parent_sampled
    local_parent_not_sampled
);

my $test = CLASS->new(%samplers);

is $test->should_sample, 'local_parent_not_sampled', 'Defaults to local not sampled';

for (
    # valid  remote  sampled  want
    [     0,      0,       0, 'local_parent_not_sampled'  ],
    [     0,      0,       1, 'local_parent_sampled'      ],
    [     0,      1,       0, 'remote_parent_not_sampled' ],
    [     0,      1,       1, 'remote_parent_sampled'     ],
    [     1,      0,       0, 'root'                      ],
    [     1,      0,       1, 'root'                      ],
    [     1,      1,       0, 'root'                      ],
    [     1,      1,       1, 'root'                      ],
) {
    my ( $valid, $remote, $sampled, $want ) = @$_;

    my $span = mock obj => add => [
        context => sub {
            mock obj => add => [
                valid       => $valid,
                remote      => $remote,
                trace_flags => sub {
                    mock obj => add => [ sampled => $sampled ]
                },
            ];
        },
    ];

    my $token = OpenTelemetry::Context->attach(
        my $context = OpenTelemetry::Trace->context_with_span($span)
    );

    is $test->should_sample( context => $context ), $want,
        sprintf 'Used %s when %s, %s, and %s',
        $want =~ s/_/ /gr,
        $valid   ? 'valid'   : 'not valid',
        $remote  ? 'remote'  : 'local',
        $sampled ? 'sampled' : 'not sampled';

    OpenTelemetry::Context->detach($token);
}

done_testing;
