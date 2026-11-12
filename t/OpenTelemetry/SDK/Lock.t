#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Lock';

use Feature::Compat::Try;
use POSIX '_exit';

is CLASS->new->enter(sub { 'inside' }), 'inside',
    'enter runs the code and returns its result';

# A lock created (and used) in this process must not wedge when it is
# first entered in a forked child: the child can never receive the token
# sitting in the parent's pipes, whose descriptor numbers may have been
# recycled there anyway.
my $lock = CLASS->new;
$lock->enter(sub { 1 });

my $child = fork;
defined $child or plan skip_all => "cannot fork: $!";

if ( !$child ) {
    my $ok = 1;
    try {
        local $SIG{ALRM} = sub { die "wedge\n" };
        alarm 10;

        for ( 1 .. 2 ) {
            die "wrong result\n"
                unless ($lock->enter(sub { 'in child' }) // '') eq 'in child';
        }

        alarm 0;
    }
    catch ($e) { $ok = 0 };

    _exit $ok ? 0 : 1;
}

waitpid $child, 0;
is $?, 0, 'a forked child can enter a lock created in the parent';

is $lock->enter(sub { 'again' }), 'again',
    'the parent can still enter it afterwards';

done_testing;
