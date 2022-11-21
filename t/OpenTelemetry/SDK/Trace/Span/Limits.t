#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Trace::Span::Limits';

subtest Defaults => sub {
    is CLASS->new, object {
        call attribute_count_limit        => 128;
        call attribute_length_limit       => U;
        call event_attribute_count_limit  => 128;
        call event_attribute_length_limit => 128;
        call event_count_limit            => 128;
        call link_attribute_count_limit   => 128;
        call link_count_limit             => 128;
    };
};

subtest 'OTEL variables' => sub {
    local %ENV = (
        OTEL_ATTRIBUTE_COUNT_LIMIT        => 99,
        OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT => 999,
    );

    is CLASS->new, object {
        call attribute_count_limit        => 99;
        call attribute_length_limit       => 999;
        call event_attribute_count_limit  => 99;
        call event_attribute_length_limit => 999;
        call event_count_limit            => 128;
        call link_attribute_count_limit   => 128;
        call link_count_limit             => 128;
    };

    subtest 'Specific variables' => sub {
        local %ENV = (
            %ENV,
            OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT         => 100,
            OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT  => 101,
            OTEL_EVENT_ATTRIBUTE_VALUE_COUNT_LIMIT  => 102,
            OTEL_EVENT_ATTRIBUTE_VALUE_LENGTH_LIMIT => 103,
            OTEL_SPAN_EVENT_COUNT_LIMIT             => 104,
            OTEL_LINK_ATTRIBUTE_COUNT_LIMIT         => 105,
            OTEL_SPAN_LINK_COUNT_LIMIT              => 106,
        );

        is CLASS->new, object {
            call attribute_count_limit        => 100;
            call attribute_length_limit       => 101;
            call event_attribute_count_limit  => 102;
            call event_attribute_length_limit => 103;
            call event_count_limit            => 104;
            call link_attribute_count_limit   => 105;
            call link_count_limit             => 106;
        };
    };

    subtest 'PERL variables' => sub {
        local %ENV = (
            %ENV,
            OTEL_PERL_SPAN_ATTRIBUTE_COUNT_LIMIT         => 200,
            OTEL_PERL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT  => 201,
            OTEL_PERL_EVENT_ATTRIBUTE_VALUE_COUNT_LIMIT  => 202,
            OTEL_PERL_EVENT_ATTRIBUTE_VALUE_LENGTH_LIMIT => 203,
            OTEL_PERL_SPAN_EVENT_COUNT_LIMIT             => 204,
            OTEL_PERL_LINK_ATTRIBUTE_COUNT_LIMIT         => 205,
            OTEL_PERL_SPAN_LINK_COUNT_LIMIT              => 206,
        );

        is CLASS->new, object {
            call attribute_count_limit        => 200;
            call attribute_length_limit       => 201;
            call event_attribute_count_limit  => 202;
            call event_attribute_length_limit => 203;
            call event_count_limit            => 204;
            call link_attribute_count_limit   => 205;
            call link_count_limit             => 206;
        };
    };
};

done_testing;
