#!/bin/sh
# shellcheck disable=SC2064,SC2139
set -eux

alias myba="$(dirname "$0")/myba.sh"

disk_usage () { du -h "$HOME" | sort -h; }

export KDF_ITERS=100  # Much faster encryption

# Prepare test
# $HOME is the default WORK_TREE dir
HOME="$(mktemp -d -t myba-test-XXXXXXX)"
export HOME
trap "rm -fr '$HOME'; trap - INT HUP EXIT" INT HUP EXIT
case "$HOME" in /tmp*) ;; *) exit 9 ;; esac

mkdir "$HOME/foo"
echo 'foo' > "$HOME/foo/.dotfile"
dd if=/dev/random bs=1MB count=1 of="$HOME/foo/other.file"
touch "$HOME/untracked.file"
touch "$HOME/ignored_by_default.so"

# Create mock git remote (i.e. GitHub)
create_mock_remote () {
    git init --bare "$1"
    rm "$1/hooks"/*.sample  # Don't pollute du output
    # Must be set on the remote server to support our `git clone --filter=`
    git -C "$1" config uploadpack.allowFilter true
}
remote_git="$HOME/remote"
remote_git2="$HOME/remote2"
create_mock_remote "$remote_git"
create_mock_remote "$remote_git2"

# Here we go, user ...

VERBOSE=1 myba init
myba add "$HOME/foo/.dotfile"
myba add "$HOME/foo/other.file"
myba git status
export PASSWORD=secret
myba commit -m "message"

myba remote add origin "$remote_git"
myba remote add origin2 "$remote_git2"
myba push origin
myba push
export PAGER=
myba log

# Somewhere else, much, much later ...

WORK_TREE="$HOME/restore"  # From here on, $WORK_TREE overrides $HOME
export WORK_TREE

myba clone "file://$(readlink -f "$remote_git")"  # Clone by uri as non-local
myba checkout HEAD
myba checkout "foo/.dotfile"
# No overwrite existing file unless forced
if myba checkout "foo/.dotfile"; then exit 2; fi
YES_OVERWRITE=1 myba checkout "foo/.dotfile"
myba restore
if myba restore; then exit 3; fi
YES_OVERWRITE=1 myba restore --squash
myba log

touch "$WORK_TREE/bar"
myba add "$WORK_TREE/bar"
myba rm foo/other.file
myba commit -m 'add bar'
myba push

disk_usage
myba gc
disk_usage
# foo + .myba + remote + remote2 + restore
test $(( $(du -s "$HOME" | cut -f1) / 1000 )) = 5

myba log

cat "$WORK_TREE/foo/.dotfile"
test "$(cat "$WORK_TREE/foo/.dotfile")" = "foo"
test "$(ls -a "$WORK_TREE")" = "\
.
..
bar
foo
.myba"

#bash  # Inspect/debug test
set +x
echo "$0: Done ok"
