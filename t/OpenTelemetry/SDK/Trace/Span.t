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
        call to_hash => {
            attributes                => {},
            end_timestamp             => U,
            events                    => [],
            instrumentation_scope     => object { call to_string => '[test:]' },
            kind                      => SPAN_KIND_INTERNAL,
            links                     => [],
            name                      => 'foo',
            parent_span_id            => INVALID_SPAN_ID,
            resource                  => U,
            span_id                   => validator(sub { length == 8 }),
            start_timestamp           => T,
            status                    => object {
                call to_hash => {
                    code => SPAN_STATUS_UNSET,
                    description => '',
                };
            },
            total_recorded_attributes => 0,
            total_recorded_events     => 0,
            total_recorded_links      => 0,
            trace_flags               => object { call flags => 0 },
            trace_id                  => validator(sub { length == 16 }),
            trace_state               => object { call to_string => '' },
        };
    };
}, 'Can create readable snapshot';

done_testing;
