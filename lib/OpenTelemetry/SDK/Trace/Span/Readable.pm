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
    field %attributes                   :reader;
    field @events                       :reader;
    field @links                        :reader;

    ADJUSTPARAMS ( $params ) {
        %attributes = %{ delete $params->{attributes} // {} };
        @events     = @{ delete $params->{events}     // [] };
        @links      = @{ delete $params->{links}      // [] };
    }

    method     trace_flags           () { $context->trace_flags   }
    method     trace_state           () { $context->trace_state   }
    method     trace_id              () { $context->trace_id      }
    method hex_trace_id              () { $context->hex_trace_id  }
    method     span_id               () { $context->span_id       }
    method hex_span_id               () { $context->hex_span_id   }
    method total_recorded_events     () { scalar @events          }
    method total_recorded_links      () { scalar @links           }
    method total_recorded_attributes () { scalar keys %attributes }

    method hex_parent_span_id () { unpack 'H*', $parent_span_id }

    method to_hash () {
        {
            attributes                => { %attributes },
            end_timestamp             => $end_timestamp,
            events                    => [ @events ],
            instrumentation_scope     => $instrumentation_scope,
            kind                      => $kind,
            links                     => [ @links ],
            name                      => $name,
            parent_span_id            => $parent_span_id,
            resource                  => $resource,
            span_id                   => $self->span_id,
            start_timestamp           => $start_timestamp,
            status                    => $status,
            total_recorded_attributes => $self->total_recorded_attributes,
            total_recorded_events     => $self->total_recorded_events,
            total_recorded_links      => $self->total_recorded_links,
            trace_flags               => $self->trace_flags,
            trace_id                  => $self->trace_id,
            trace_state               => $self->trace_state,
        }
    }
}
