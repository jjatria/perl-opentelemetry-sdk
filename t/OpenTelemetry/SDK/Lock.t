#!/usr/bin/env perl

use Test2::V0 -target => 'OpenTelemetry::SDK::Lock';

use experimental 'signatures';
use Feature::Compat::Try;
use POSIX qw( _exit dup2 sysconf _SC_OPEN_MAX );
use Mutex;

# The descriptors to recycle in the child's sweep: everything above the
# standard three. A real listing is used where the platform offers one;
# otherwise the descriptor range is probed, the same fallback the batch
# processor's own descriptor sweep uses. Pointing a free slot at the
# probe pipe is as harmless as doing it to a live one.
sub sweep_fds {
    my $list = sub ( $dir ) {
        return ()
            unless opendir my $dh, $dir;
        my @fds = grep { /^\d+\z/ && ( 0 + $_ ) > 2 } readdir $dh;
        closedir $dh;

        return @fds ? ( sort { $a <=> $b } map { 0 + $_ } @fds ) : ();
    };

    for my $dir ( '/proc/self/fd', '/dev/fd' ) {
        my @fds = $list->( $dir );
        return @fds
            if @fds;
    }

    my $max = sysconf( _SC_OPEN_MAX );
    $max = 1_024 if !defined $max || $max < 2;
    $max = 65_536 if $max > 65_536;

    # Stop short of the top of the range: the wrapper rebuilds its Mutex
    # in the child, and the new token pipe needs free descriptors to be
    # allocated from.
    my $top = $max - 8;
    return $top < 3 ? () : ( 3 .. $top );
}

is CLASS->new->enter(sub { 'inside' }), 'inside',
    'enter runs the code and returns its result';

# create a raw Mutex and one of our implementation
my $raw = Mutex->new;
$raw->enter(sub { 1 });

my $lock = CLASS->new;
$lock->enter(sub { 1 });

# Snapshot with both locks alive, so that the child sweep below also
# recycles the descriptors of their token pipes.
my @fds = sweep_fds();

# Enter the given lock, twice, in a forked child whose inherited
# descriptors have all been pointed at a pipe that is never written to
# (what the batch processor's subprocess effectively does when it sweeps
# its inherited descriptors and reuses their numbers). The child exits 0
# when the lock worked, 1 when entering blocked or misbehaved, and 2 when
# the probe could not be set up.
sub child_enter_status ( $lock, $alarm_secs ) {
    # A working fork is a hard requirement of this distribution (the batch
    # processor runs on a forked subprocess), so a failed fork here is a
    # broken environment, not a platform to skip on.
    my $child = fork;
    defined $child
        or bail_out "cannot fork: $!";

    if ( !$child ) {
        my $ok = 1;

        my $probe_r;
        my $probe_w;
        pipe $probe_r, $probe_w
            or _exit 2;
        my $keep_reader = fileno $probe_r;
        my $keep_writer = fileno $probe_w;
        dup2( $keep_reader, $_ )
            for grep { $_ != $keep_reader && $_ != $keep_writer } @fds;

        try {
            local $SIG{ALRM} = sub { die "blocked\n" };
            alarm $alarm_secs;

            for ( 1 .. 2 ) {
                die "wrong result\n"
                    unless ($lock->enter(sub { 'in child' }) // '') eq 'in child';
            }

            alarm 0;
        }
        catch ($e) {
            $ok = 0;
        };

        _exit $ok ? 0 : 1;
    }

    waitpid $child, 0;
    return $?;
}

# Entering a Mutex built in the parent keeps working across a plain fork,
# for as long as its token descriptors survive intact. the
# sweep is what turns the situation into one only a lock rebuilt in the
# child survives, so a plain Mutex is expected to block forever in it.
# A block never resolves by itself, so a short alarm tells the outcomes
# apart (and also limits this test's runtime).
# The expected status is the child's exit 1 exactly, probe setup trouble
# xits 2, so it cannot be mistaken for a blocked enter.
is child_enter_status( $raw, 3 ), 1 << 8,
    'a forked child whose file descriptors were recycled blocks forever when using a plain Mutex';

is child_enter_status( $lock, 10 ), 0,
    'a forked child whose file descriptors were recycled can enter our lock';

is $lock->enter(sub { 'again' }), 'again',
    'the parent can still enter it afterwards';

done_testing;
