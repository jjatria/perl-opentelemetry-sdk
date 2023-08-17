#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Trace::Span';

use OpenTelemetry::Constants qw(
    SPAN_KIND_INTERNAL
    SPAN_STATUS_UNSET
);
use OpenTelemetry::Trace;
use OpenTelemetry::Constants qw(
    SPAN_STATUS_UNSET
    SPAN_KIND_INTERNAL
    INVALID_SPAN_ID
);
use OpenTelemetry::SDK::InstrumentationScope;

my $scope = OpenTelemetry::SDK::InstrumentationScope->new( name => 'test' );

is CLASS->new( name => 'foo', scope => $scope ), object {
    call snapshot => object {
        prop isa => 'OpenTelemetry::SDK::Trace::Span::Readable';
        call attributes            => {};
        call end_timestamp         => U;
        call_list events           => [];
        call instrumentation_scope => object { call to_string => '[test:]' };
        call kind                  => SPAN_KIND_INTERNAL;
        call_list links            => [];
        call name                  => 'foo';
        call parent_span_id        => INVALID_SPAN_ID;
        call resource              => U;
        call span_id               => validator(sub { length == 8 });
        call start_timestamp       => T;
        call dropped_attributes    => 0;
        call dropped_events        => 0;
        call dropped_links         => 0;
        call trace_flags           => object { call flags => 0 };
        call trace_id              => validator(sub { length == 16 });
        call trace_state           => object { call to_string => '' };
        call status => object {
           call code        => SPAN_STATUS_UNSET;
           call description => '';
        };
    };
}, 'Can create readable snapshot';

done_testing;
