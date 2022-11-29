#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Trace::Span';

use OpenTelemetry::Trace;

is CLASS->new( name => 'foo' ), object {
    call snapshot => object {
        prop isa  => 'OpenTelemetry::SDK::Trace::Span::Snapshot';
        call      name                      => 'foo';
        call      span_id                   => validator sub { length == 8 };
        call      parent_span_id            => validator sub { unpack('H*', $_) eq '0000000000000000' };
        call      kind                      => 'INTERNAL';
        call      status                    => object { call unset => T };
        call      total_recorded_attributes => 0;
        call      total_recorded_events     => 0;
        call      total_recorded_links      => 0;
        call      start_timestamp           => T;
        call      end_timestamp             => U;
        call      attributes                => {};
        call_list links                     => [];
        call_list events                    => [];
        call      resource                  => 1;
        call      instrumentation_scope     => 1;
        call      trace_id                  => validator sub { length == 16 };
        call      trace_flags               => 0;
        call      trace_state               => object { };
    };
}, 'Can create readable snapshot';

done_testing;
