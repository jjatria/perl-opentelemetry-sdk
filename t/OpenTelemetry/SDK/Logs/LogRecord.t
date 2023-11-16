#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Logs::LogRecord';
use Test2::Tools::OpenTelemetry;

use OpenTelemetry::Constants '-log';
use OpenTelemetry::Trace;
use OpenTelemetry::SDK::InstrumentationScope;
use OpenTelemetry::X;

my $scope = OpenTelemetry::SDK::InstrumentationScope->new( name => 'test' );
my $span_context = OpenTelemetry::Trace::SpanContext->new;

like dies { CLASS->new },
    qr/^Required parameter .* is missing/,
    'Constructor has required parameters';

use OpenTelemetry::Trace;
use OpenTelemetry::SDK::Resource;

is my $record = CLASS->new(
    attributes            => my $attributes = { foo => { bar => { baz => 123 } } },
    context               => $span_context,
    severity_text         => '' . LOG_LEVEL_WARN,
    severity_number       =>  0 + LOG_LEVEL_WARN,
    resource              => OpenTelemetry::SDK::Resource->new,
    instrumentation_scope => $scope,
    body                  => 'Reticulating splines',
) => object {
    call attributes            => { foo => { bar => { baz => 123 } } };
    call timestamp             => U;
    call observed_timestamp    => T;
    call severity_text         => 'WARN';
    call severity_number       => 13;
    call resource              => object { prop isa => 'OpenTelemetry::SDK::Resource' };
    call instrumentation_scope => object { call name => 'test' };
    call body                  => 'Reticulating splines';
    call dropped_attributes    => 0; # TODO: hard-coded for now
    call trace_flags           => $span_context->trace_flags;
    call trace_state           => $span_context->trace_state;
    call trace_id              => $span_context->trace_id;
    call hex_trace_id          => $span_context->hex_trace_id;
    call span_id               => $span_context->span_id;
    call hex_span_id           => $span_context->hex_span_id;
};

$attributes->{foo} = 123;

is $record->attributes => { foo => { bar => { baz => 123 } } },
    'Attributes are read only';

{
    my $todo = todo 'OTel code should not die at runtime';
    ok lives {
        my $attr = $record->attributes;
        $attr->{foo} = 'xxx';
    };
}

is $record->attributes => { foo => { bar => { baz => 123 } } },
    'Attributes are read only';

done_testing;
