package OpenTelemetry::SDK;
# ABSTRACT: An implementation of the OpenTelemetry SDK for Perl

our $VERSION = '0.001';

use strict;
use warnings;
use experimental qw( try signatures );

use OpenTelemetry;
use OpenTelemetry::SDK::Configurator;

# Experimental
sub import ( $class, @options ) {
    while ( my $option = shift @options ) {
        if ( $option eq '-configure' ) {
            $class->configure;
            next;
        }

        die "Unknown import option: $option";
    }
}

sub configure ( $, $block = undef ) {
    try {
        my $configurator = OpenTelemetry::SDK::Configurator->new;
        $configurator->$block if $block;
        $configurator->configure;
    }
    catch ($e) {
        OpenTelemetry->handle_error(
            exception => $e,
            message   => "Unexpected configuration error: $e"
        );
    }
}

1;
