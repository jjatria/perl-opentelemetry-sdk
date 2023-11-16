#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Exporter::Console';
use Test2::Tools::Spec;

use Test2::Tools::OpenTelemetry;
use OpenTelemetry::Constants -all;
use OpenTelemetry::SDK::InstrumentationScope;
use OpenTelemetry::Trace;
use OpenTelemetry::SDK::Trace::Span;
use OpenTelemetry::SDK::Logs::LogRecord;
use OpenTelemetry::Trace::SpanContext;
use OpenTelemetry::SDK::Resource;

my $scope = OpenTelemetry::SDK::InstrumentationScope->new( name => 'test' );

my $span_context = OpenTelemetry::Trace::SpanContext->new(
    trace_id => "\1" x 16,
    span_id  => "\1" x 8,
);

my $context = OpenTelemetry::Trace->context_with_span(
    OpenTelemetry::Trace->non_recording_span($span_context),
);

describe Export => sub {
    my ( $data, $exported );

    case Span => sub {
        $data = OpenTelemetry::SDK::Trace::Span->new(
            name       => 'test-span',
            scope      => $scope,
            attributes => { foo => 123 },
            start      => 123456789.1234,
            context    => $span_context,
            links      => [
                {
                    context => $span_context,
                    attributes => { link => 123 },
                },
                {
                    context => OpenTelemetry::Trace::SpanContext->INVALID,
                    attributes => { dropped => 1 },
                },
            ],
        )->add_event(
            name       => "event",
            timestamp  => 123456789,
            attributes => { event => 123 },
        )->snapshot;

        $exported = <<'DUMP' =~ s/\n//gr . "\n";
{'attributes' => {'foo' => 123},'dropped_attributes' => 0,'dropped_e
vents' => 0,'dropped_links' => 0,'end_timestamp' => undef,'events' =
> [{'attributes' => {'event' => 123},'dropped_attributes' => 0,'name
' => 'event','timestamp' => 123456789}],'instrumentation_scope' => {
'name' => 'test','version' => ''},'kind' => 1,'links' => [{'attribut
es' => {'link' => 123},'dropped_attributes' => 0,'span_id' => '01010
10101010101','trace_id' => '01010101010101010101010101010101'}],'nam
e' => 'test-span','parent_span_id' => '0000000000000000','resource'
 => {},'span_id' => '0101010101010101','start_timestamp' => '1234567
89.1234','status' => {'code' => 0,'description' => ''},'trace_flags'
 => 0,'trace_id' => '01010101010101010101010101010101','trace_state'
 => ''}
DUMP
    };

    case LogRecord => sub {
        $data = OpenTelemetry::SDK::Logs::LogRecord->new(
            attributes            => { foo => { bar => { baz => 123 } } },
            body                  => 'Reticulating splines',
            context               => $context,
            instrumentation_scope => $scope,
            severity_number       =>  0 + LOG_LEVEL_WARN,
            severity_text         => '' . LOG_LEVEL_WARN,
            observed_timestamp    => '1750974669.96714',
            resource              => OpenTelemetry::SDK::Resource->empty(
                attributes => { 'some.attribute' => 'some value' },
            ),
        );

        $exported = <<'DUMP' =~ s/\n//gr . "\n";
{'attributes' => {'foo' => {'bar' => {'baz' => 123}}},'body' => 'Ret
iculating splines','dropped_attributes' => 0,'flags' => 0,'instrumen
tation_scope' => {'name' => 'test','version' => ''},'observed_timest
amp' => '1750974669.96714','resource' => {'some.attribute' => 'some
 value'},'severity_number' => 13,'severity_text' => 'WARN','span_id'
 => '0101010101010101','timestamp' => undef,'trace_id' => '010101010
10101010101010101010101'}
DUMP
    };

    it Works => { flat => 1 } => sub {
        open my $handle, '>', \my $out or die $!;

        is my $exporter = CLASS->new( handle => $handle ), object {
            prop isa => $CLASS;
        }, 'Can create exporter';

        is $exporter->export( [$data], 100 ), TRACE_EXPORT_SUCCESS,
            'Exporting is successful';

        is $out, $exported, 'Exported data';
    };
};

tests Other => sub {
    open my $handle, '>', \my $out or die $!;

    my $exporter = CLASS->new( handle => $handle );

    $out = '';
    is $exporter->export([]), TRACE_EXPORT_SUCCESS, 'Timeout is optional';

    is $out, '', 'Nothing exported if no spans are given';

    is $exporter->force_flush( 100 )->get, TRACE_EXPORT_SUCCESS, 'Can force flush';
    is $exporter->force_flush->get, TRACE_EXPORT_SUCCESS, 'Flush timeout is optional';

    is $exporter->shutdown( 100 )->get, TRACE_EXPORT_SUCCESS, 'Can shutdown exporter';
    is $exporter->shutdown->get, TRACE_EXPORT_SUCCESS, 'Shutdown timeout is optional';

    $out = '';
    is $exporter->export([mock]), TRACE_EXPORT_FAILURE,
        'Exporter does not export if it has been shutdown';

    is $out, '', 'Nothing exported on failure';
};


done_testing;
