#!/bin/bash
set -eu

new_words="$(comm <(<"$1" aspell list | sort -u) <(sort -u "$(dirname "$0")/aspell-ignorewords.txt") -23)"
echo "Are these typos?"
echo
echo "$new_words"
echo "$new_words" | grep -q . && exit 1 || true
