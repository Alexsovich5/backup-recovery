#!/bin/bash
#
# Checks on a directory that holds PKI key files. Source this file; it
# defines functions only.

# keydir_check DIR "UID..." [FILE...]
# Returns 0 when DIR is a real directory (not a symlink) owned by one of
# the listed uids and not writable by group or others, and every listed
# FILE that exists in it is a regular file (not a symlink) owned by one of
# the uids. A missing FILE is fine: it has not been generated yet. Prints
# the reason to stderr and returns 1 otherwise. Callers run this before
# they chown, chmod or read anything in DIR, because those follow symlinks
# and would act on whatever the link points to.
keydir_check() {
    local dir=$1 uids=$2 f owner mode
    shift 2
    if [ -L "$dir" ]; then
        echo "key directory $dir is a symlink" >&2
        return 1
    fi
    if [ ! -d "$dir" ]; then
        echo "key directory $dir is not a directory" >&2
        return 1
    fi
    owner=$(stat -c %u "$dir")
    case " $uids " in
        *" $owner "*) ;;
        *)
            echo "key directory $dir has unexpected owner uid $owner" >&2
            return 1
            ;;
    esac
    mode=$(stat -c %a "$dir")
    if [ $((0$mode & 022)) -ne 0 ]; then
        echo "key directory $dir is writable by group or others (mode $mode)" >&2
        return 1
    fi
    for f in "$@"; do
        if [ -L "$dir/$f" ]; then
            echo "key file $dir/$f is a symlink" >&2
            return 1
        fi
        [ -e "$dir/$f" ] || continue
        if [ ! -f "$dir/$f" ]; then
            echo "key file $dir/$f is not a regular file" >&2
            return 1
        fi
        owner=$(stat -c %u "$dir/$f")
        case " $uids " in
            *" $owner "*) ;;
            *)
                echo "key file $dir/$f has unexpected owner uid $owner" >&2
                return 1
                ;;
        esac
    done
    return 0
}
