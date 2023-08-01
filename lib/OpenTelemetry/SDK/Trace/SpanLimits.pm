use Object::Pad ':experimental(init_expr)';
# ABSTRACT: A class that governs the configuration of spans

package OpenTelemetry::SDK::Trace::SpanLimits;

our $VERSION = '0.001';

class OpenTelemetry::SDK::Trace::SpanLimits {
    use Ref::Util 'is_arrayref';
    use List::Util 'first';
    use Carp 'croak';
    use OpenTelemetry::Common 'config';

    use namespace::clean -except => 'new';

    field $attribute_count_limit        :reader = config(qw( SPAN_ATTRIBUTE_COUNT_LIMIT          ATTRIBUTE_COUNT_LIMIT        )) // 128;
    field $attribute_length_limit       :reader = config(qw( SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT   ATTRIBUTE_VALUE_LENGTH_LIMIT ));
    field $event_attribute_count_limit  :reader = config(qw( EVENT_ATTRIBUTE_VALUE_COUNT_LIMIT   ATTRIBUTE_COUNT_LIMIT        )) // 128;
    field $event_attribute_length_limit :reader = config(qw( EVENT_ATTRIBUTE_VALUE_LENGTH_LIMIT  ATTRIBUTE_VALUE_LENGTH_LIMIT )) // 128;
    field $event_count_limit            :reader = config(qw( SPAN_EVENT_COUNT_LIMIT                                           )) // 128;
    field $link_attribute_count_limit   :reader = config(qw( LINK_ATTRIBUTE_COUNT_LIMIT                                       )) // 128;
    field $link_count_limit             :reader = config(qw( SPAN_LINK_COUNT_LIMIT                                            )) // 128;

    ADJUST {
        croak "attribute_count_limit must be positive, it is '$attribute_count_limit'"
            unless $attribute_count_limit > 0;

        croak "attribute_length_limit must be at leastt 32, it is '$attribute_length_limit'"
            unless ( $attribute_length_limit // 32 ) >= 32;

        croak "event_attribute_count_limit must be positive, it is '$event_attribute_count_limit'"
            unless $event_attribute_count_limit > 0;

        croak "event_attribute_length_limit must be at least 32, it is '$event_attribute_length_limit'"
            unless $event_attribute_length_limit >= 32;

        croak "event_count_limit must be postive, it is '$event_count_limit'"
            unless $event_count_limit > 0;

        croak "link_attribute_count_limit must be positive: it is '$link_attribute_count_limit'"
            unless $link_attribute_count_limit > 0;

        croak "link_count_limit must be positive: it is '$link_count_limit'"
            unless $link_count_limit;
    }
}
