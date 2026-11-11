use Object::Pad ':experimental(init_expr)';
# ABSTRACT: A fork-safe wrapper around Mutex

package OpenTelemetry::SDK::Lock;

our $VERSION = '0.102';

class OpenTelemetry::SDK::Lock {
    use Mutex;

    field $created_pid = $$;
    field $mutex       = Mutex->new;

    # Mutex is fork-blind: a lock inherited through fork() still refers
    # to the token pipes created in its parent, so entering it would
    # block reading bytes the child can never receive (or, once those
    # descriptor numbers have been recycled for other handles, read from
    # something else entirely). Detect the fork and build a fresh lock
    # before ever touching the inherited pipes.
    method enter ($code) {
        if ( $$ != $created_pid ) {
            $created_pid = $$;

            # Letting go of the inherited Mutex here is safe: its
            # finalizer neither returns a token this process never took,
            # nor closes the pipes, since those belong to the process
            # that created it.
            $mutex = Mutex->new;
        }

        return $mutex->enter($code);
    }
}

1;
