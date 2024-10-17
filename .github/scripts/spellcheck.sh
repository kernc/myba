#!/bin/bash

new_words="$(comm <(<README.full.md aspell list | sort -u) <(sort -u "$(dirname "$0")/aspell-ignorewords.txt") -23)"
echo "Are these typos?"
echo
echo "$new_words"
echo "$new_words" | grep -q . && exit 1 || true
