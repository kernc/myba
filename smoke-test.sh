#!/bin/bash
# shellcheck disable=SC2064,SC2139
set -eux

PS4="$(
    if [ "${LINENO:-}" ] && [ "${BASH_VERSION:-}" ]; then lineno=':$LINENO>'; fi
    printf "\033[36;40;1m+%s${lineno:-}\033[0m " "$0"
)"
export PS4
export LC_ALL=C

_libdir="$(dirname "$0")"

shell="$(ps -p $$ -o comm=)"
case "$shell" in bash|-bash|dash|-dash|zsh|-zsh|sh|-sh) ;; *) shell= ;; esac

myba () { $shell "$_libdir/myba.sh" "$@"; }  # Invoke using current shell

disk_usage () { du -t 10K -h "$HOME" | sort -h; }

export KDF_ITERS=100  # Much faster encryption

# Prepare test
# $HOME is the default WORK_TREE dir
HOME="$(mktemp -d -t myba-test-XXXXXXX)"
export HOME
trap "rm -fr \"$HOME\"; trap - INT HUP EXIT TERM" INT HUP TERM EXIT
if [ ! "${CI:-}" ]; then case "$HOME" in /tmp*|/var/*) ;; *) exit 9 ;; esac; fi

mkdir "$HOME/foo"
echo 'foo' > "$HOME/foo/.dotfile"
dd if=/dev/random bs=1000000 count=1 of="$HOME/foo/other.file"
echo 'bar' > "$HOME/renamed.file"
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

title () { echo; echo "$@"; echo; }

title 'Here we go, user does ...'

myba help || true
VERBOSE=1 myba init
myba add "$HOME/foo/.dotfile"
myba add "$HOME/foo/other.file"
myba add "$HOME/renamed.file"
myba git status
export PASSWORD=secret
myba commit -m "message"

myba remote add origin "$remote_git"
myba remote add origin2 "$remote_git2"
#myba push origin  # XXX: Fails on CI but wfm
myba push
export PAGER=
myba log

# Test to make https://github.com/kernc/myba/issues/1 easier to detect
myba git_enc log || exit 15

title 'Somewhere else, much, much later ...'

WORK_TREE="$HOME/restore"  # From here on, $WORK_TREE overrides $HOME
export WORK_TREE

myba clone "file://$(readlink -f "$remote_git")"  # Clone by uri as non-local
myba checkout HEAD
title 'Ensure restoration script is present in the encrypted repo'
stat "$WORK_TREE/.myba/_encrypted/myba.sh"
title 'No overwrite existing file unless forced'
myba checkout "foo/.dotfile"
if setsid myba checkout "foo/.dotfile"; then exit 2; fi
YES_OVERWRITE=1 myba checkout "foo/.dotfile"
unset YES_OVERWRITE  # Fix for buggy macOS shell

title '(Re-)decrypt encrypted commits'
myba decrypt
if myba decrypt; then exit 3; fi
YES_OVERWRITE=1 myba decrypt --squash
myba log

title 'Re-encryption adds an encrypted repo commit'
PASSWORD=new  # This is now the new password now
myba reencrypt
test "$(myba git_enc ls-files | wc -l)" -eq $((3 + 1 + 1))

title 'Another commit from this side'
touch "$WORK_TREE/bar"
myba add "$WORK_TREE/bar"
myba rm foo/other.file
myba checkout renamed.file
test "$(cat "$WORK_TREE/renamed.file")" = "bar"
cp "$WORK_TREE/renamed.file" "$WORK_TREE/renamed.file.2"
myba add renamed.file.2
myba git mv renamed.file renamed.file.3
myba commit -m 'add bar'
myba push

disk_usage
myba gc
disk_usage
# foo + .myba + restore + overhead (excludes: remote + remote2)
max_size=4500  # Note, this appears to be CI-dependent
case "$OSTYPE" in darwin*) max_size=$(( $max_size + 3000 )) ;; esac  # 🤷
du -s -B 1K -t 500K "$HOME/foo" "$HOME/.myba" "$HOME/restore"
size_on_disk="$(
    du -s -B 1K -t 500K "$HOME/foo" "$HOME/.myba" "$HOME/restore" |
    cut -f1 | paste -s -d + - | bc
)"
test "$size_on_disk" -lt $max_size

myba log

cat "$WORK_TREE/foo/.dotfile"
test "$(cat "$WORK_TREE/foo/.dotfile")" = "foo"
test "$(ls -a "$WORK_TREE")" = "\
.
..
.myba
bar
foo
renamed.file.2
renamed.file.3"

myba ls-files
myba largest

#bash  # Inspect/debug test
set +x
echo "$0: Done ok"
