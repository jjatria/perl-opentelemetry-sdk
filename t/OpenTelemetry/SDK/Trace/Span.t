#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Trace::Span';

use OpenTelemetry::Constants qw(
    SPAN_KIND_INTERNAL
    SPAN_STATUS_UNSET
);
use OpenTelemetry::Trace;
use OpenTelemetry::SDK::InstrumentationScope;

my $scope = OpenTelemetry::SDK::InstrumentationScope->new( name => 'test' );

is CLASS->new( name => 'foo', scope => $scope ), object {
    call snapshot => +{
        name                      => 'foo',
        span_id                   => match qr/^[0-9a-z]{16}$/,
        parent_span_id            => DNE,
        kind                      => SPAN_KIND_INTERNAL,
        status                    => SPAN_STATUS_UNSET,
        total_recorded_attributes => 0,
        total_recorded_events     => 0,
        total_recorded_links      => 0,
        start_timestamp           => T,
        end_timestamp             => U,
        attributes                => {},
        links                     => [],
        events                    => [],
        resource                  => {},
        instrumentation_scope     => '[test:]',
        trace_id                  => match qr/^[0-9a-z]{32}$/,
        trace_flags               => 0,
        trace_state               => '',
    };
}, 'Can create readable snapshot';

done_testing;
