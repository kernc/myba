#!/bin/bash
set -eux
export LC_ALL=C

_libdir="$(realpath "${0%/*}/..")"
shell="$(ps -p $$ -o comm=)"
case "$shell" in bash|-bash|dash|-dash|zsh|-zsh|sh|-sh) ;; *) shell= ;; esac
myba () { $shell "$_libdir/myba.sh" "$@"; }

export KDF_ITERS=10  # Fast
unset WORK_TREE
unset XDG_CONFIG_HOME
HOME="$(mktemp -d -t myba-decrypt-test-XXXXXXX)"
export HOME
trap "rm -fr \"$HOME\"; trap - INT HUP EXIT TERM" INT HUP TERM EXIT
cd

# Initialize
myba init

export VERBOSE=1

# Create a file and commit it
echo "a" >a.file
myba add a.file
export PASSWORD=secret
myba commit

# Create a new switch (branch) "feature"
myba rm a.file
myba commit -m 'rm-pnly commit'

YES_OVERWRITE=1 myba decrypt

myba git log --name-status | cat

myba git_enc log --name-status | cat


echo "Test passed!"
