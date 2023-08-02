use Object::Pad ':experimental(init_expr)';

package OpenTelemetry::SDK::Trace::Span::Readable;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Trace::Span::Readable {
    use OpenTelemetry::Constants 'INVALID_SPAN_ID';

    field $context               :param;
    field $end_timestamp         :param :reader;
    field $instrumentation_scope :param :reader;
    field $kind                  :param :reader;
    field $name                  :param :reader;
    field $parent_span_id        :param :reader //= INVALID_SPAN_ID;
    field $resource              :param :reader;
    field $start_timestamp       :param :reader;
    field $status                :param :reader;
    field $attributes            :param :reader //= {};
    field @events                       :reader;
    field @links                        :reader;

    ADJUSTPARAMS ( $params ) {
        @events     = @{ delete $params->{events} // [] };
        @links      = @{ delete $params->{links}  // [] };
    }

    method     trace_flags           () { $context->trace_flags    }
    method     trace_state           () { $context->trace_state    }
    method     trace_id              () { $context->trace_id       }
    method hex_trace_id              () { $context->hex_trace_id   }
    method     span_id               () { $context->span_id        }
    method hex_span_id               () { $context->hex_span_id    }
    method total_recorded_events     () { scalar @events           }
    method total_recorded_links      () { scalar @links            }
    method total_recorded_attributes () { scalar keys %$attributes }

    method hex_parent_span_id () { unpack 'H*', $parent_span_id }
}
