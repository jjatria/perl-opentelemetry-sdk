use Object::Pad;

package OpenTelemetry::SDK::Trace::Span::Snapshot;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Trace::Span::Snapshot {
    has $name                      :param :reader; # String
    has $kind                      :param :reader; # Symbol: :internal, :producer, :consumer, :client, :server
    has $status                    :param :reader; # Status
    has $parent_span_id            :param :reader; # String (8 byte binary), may be OpenTelemetry::Trace::INVALID_SPAN_ID
    has $total_recorded_attributes :param :reader; # Integer
    has $total_recorded_events     :param :reader; # Integer
    has $total_recorded_links      :param :reader; # Integer
    has $start_timestamp           :param :reader; # Integer nanoseconds since Epoch
    has $end_timestamp             :param :reader; # Integer nanoseconds since Epoch
    has $attributes                :param :reader; # optional Hash{String => String, Numeric, Boolean, Array<String, Numeric, Boolean>}
    has @links                     :reader;         # optional Array[OpenTelemetry::Trace::Link]
    has @events                    :reader;         # optional Array[Event]
    has $resource                  :param :reader; # OpenTelemetry::SDK::Resources::Resource
    has $instrumentation_scope     :param :reader; # OpenTelemetry::SDK::InstrumentationScope
    has $span_id                   :param :reader; # String (8 byte binary)
    has $trace_id                  :param :reader; # String (16-byte binary)
    has $trace_flags               :param :reader; # Integer (8-bit byte of bit flags)
    has $trace_state               :param :reader; # OpenTelemetry::Trace::Tracestate

    ADJUST ( $params ) {
        @events = @{ delete $params->{events} // [] };
        @links  = @{ delete $params->{links}  // [] };
    }
}
