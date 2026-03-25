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
HOME="$(mktemp -d -t myba-switch-test-XXXXXXX)"
export HOME
trap "rm -fr \"$HOME\"; trap - INT HUP EXIT TERM" INT HUP TERM EXIT
cd

# Initialize
myba init

# Create a file and commit it
echo "main content" >main.file
echo "main content" >main.file2
myba add main.file main.file2
export PASSWORD=secret
myba commit -m "commit on main"

# Create a new switch (branch) "feature"
myba switch feature

# We should be on feature branch now.
# Check if file.txt is still there and has same content
test "$(cat main.file)" = "main content"

# Modify file.txt on feature branch and commit
echo "feature content" >main.file
echo "feature content" >feat.file
myba add main.file feat.file
myba commit -m "commit on feature"

# Switch back to main
myba switch main
# Even after switch, files remain unchanged until explicit checkout
test "$(cat main.file)" = "feature content"
test "$(cat feat.file)" = "feature content"

# Now the real test: switch to feature, but have UNCOMMITTED changes
echo foo >untracked.file
echo foo >main.file

# Switch to feature
# The intent is that user's current worktree changes always persist (e.g. are stashed and restored)
# Nothing from the branch should overwrite anything on the filesystem!
myba switch feature

# After switching to feature, our local changes should still be there!
test foo = "$(cat untracked.file)"
test foo = "$(cat main.file)"

# Now modify them once more on feature
echo bar >main.file
rm main.file2

# Switch back to main
myba switch main
test foo = "$(cat untracked.file)"
test bar = "$(cat main.file)"
test ! -e main.file2

echo "Test passed!"
