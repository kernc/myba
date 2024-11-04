#!/bin/sh
# myba - Secure, distributed, encrypted backups based on `sh` shell and `git` (and `openssl enc` or `gpg`)
#
# Basically your beloved git, but with underlying two repos:
#   * bare, local-only _plain repo_ to track changes upon local,
#     plaintext (and binary) files, set e.g. to your $HOME,
#   * _encrypted repo_ that holds the encrypted blobs.
# Only the encrypted repo is ever synced with configured remotes.
# Every commit into the plain repo creates a commit in the encrypted repo.
# Commits in the encrypted repo carry base64-encoded encrypted commit metadata
# of the plain repo.
# Additional files `$ENC_REPO/manifest/<plain_repo_commit_hash>` with
# with line format: `<enc_path>\t<plain_path>`.
# Encrypted paths are like "$ENC_REPO/abc/def/rest-of-hash" and are _deterministic_,
# dependent upon the plain pathname and chosen password! The multi-level fs hierarchy
# is for near maximum efficiency of `git sparse-checkout`.
# Encrypted blobs are also encrypted deterministically, based on hash of the plain
# content and chosen password.
#
# This is an expected shell workflow:
#
#     $ export WORK_TREE=  # Defaults to $HOME
#     $ myba init
#     $ myba add .config/git/config .vimrc .ssh/config
#     $ PASSWORD=secret myba commit -m 'my config files'  # Reads pw from stdin if unset
#     $ myba rm .vimrc
#     $ myba commit -m 'no longer use vim'
#     $ myba remote add origin "$GITHUB_REPO"
#     $ myba push origin
#
# Somewhere, sometime later, we may only have access to encrypted repo:
#
#     $ WORK_TREE="$HOME" myba clone "$GITHUB_REPO"
#     $ myba log   # See plain commit info
#     $ myba diff  # See changes of tracked $WORK_TREE files
#     $ myba checkout $COMMIT  # Hash from plain or encrypted repo
#     $ myba checkout .config .ssh  # Checkout dirs and everything under
#     $ [ -f ~/.config/git/config ] && [ -d ~/.ssh ]   # Files are restored
#
# The last command Uses sparse-checkout to fetch and unencrypt the right blobs.
# The checkout command asks before overwriting existing files in $WORK_TREE!
#
# See usage AND CODE for details.
#

# shellcheck disable=SC1003,SC2064,SC2086,SC2162,SC3045

set -eu

# Configuration via env vars
WORK_TREE="${WORK_TREE:-${HOME:-~}}"
PLAIN_REPO="$WORK_TREE/.myba"
ENC_REPO="$PLAIN_REPO/_encrypted"
#PASSWORD=  # Replace with your encryption password or if null, read stdin

usage () {
    echo "Usage: $0 <subcommand> [options]"
    echo "Subcommands:"
    echo "  init                  Initialize repos in \$WORK_TREE (default: \$HOME)"
    echo "  add [OPTS] PATH...    Stage files for backup/version tracking"
    echo "  rm PATH...            Stage-remove files from future backups/version control"
    echo "  commit [OPTS]         Commit staged changes of tracked files as a snapshot"
    echo "  push [REMOTE]         Encrypt and push files to remote repo(s) (default: all)"
    echo "  pull [REMOTE]         Pull encrypted commits from a promisor remote"
    echo "  clone REPO_URL        Clone an encrypted repo and init from it"
    echo "  remote CMD [OPTS]     Manage remotes of the encrypted repo"
    echo "  restore [--squash]    Reconstruct plain repo commits from encrypted commits"
    echo "  diff [OPTS]           Compare changes between plain repo revisions"
    echo "  log [OPTS]            Show commit log of the plain repo"
    echo "  checkout PATH...      Sparse-checkout and decrypt files into \$WORK_TREE"
    echo "  checkout COMMIT       Switch files to a commit of plain or encrypted repo"
    echo "  gc                    Garbage collect, remove synced encrypted packs"
    echo "  git CMD [OPTS]        Inspect/execute raw git commands inside plain repo"
    echo "  git_enc CMD [OPTS]    Inspect/execute raw git commands inside encrypted repo"
    echo
    echo 'Env vars: WORK_TREE, PLAIN_REPO, PASSWORD USE_GPG, VERBOSE, YES_OVERWRITE'
    echo 'For a full list and info, see: https://github.com/kernc/myba/'
    exit 1
}

warn () { echo "$(basename "$0" .sh): $*" >&2; }

_tab="$(printf '\t')"

git_plain () { git --work-tree="$WORK_TREE" --git-dir="$PLAIN_REPO" "$@"; }
git_enc () { git -C "$ENC_REPO" "$@"; }

_is_binary_stream () { dd bs=8192 count=1 status=none | LC_ALL=C tr -dc '\000' | LC_ALL=C grep -qa .; }
_mktemp () { mktemp -t "$(basename "$0" .sh)-XXXXXXX" "$@"; }
_file_size () { stat -c%s "$@" 2>/dev/null || stat -f%z "$@"; }

_ask_pw () {
    if [ -z "${PASSWORD+1}" ]; then
        stty -echo
        IFS= read -p "Enter encryption password: " -r PASSWORD
        echo
        stty echo
    fi

    # Set up encryption via OpenSSL
    _encrypt_func=_enc_openssl
    _decrypt_func=_dec_openssl
    _armor_flags='-base64 -A'
    _kdf_iters="${KDF_ITERS:-321731}"
    # Set up encryption via GPG
    if [ "${USE_GPG+1}" ]; then
        _encrypt_func=_enc_gpg
        _decrypt_func=_dec_gpg
        _armor_flags='--armor'
        _kdf_iters="${KDF_ITERS:-159011733}"  # OpenSSL and GPG use different KDF algos
    fi
}
_encrypted_path () (
    set +x  # Avoid terminal noise and secret-spilling in this subshell
    echo "$1$PASSWORD" |
        shasum -a512 |
        cut -c-128 |
        sed -E 's,(...)(...)(...)(.*),\1/\2/\3/\4,'
)
_enc_openssl () {
    openssl enc -aes-256-ctr -pbkdf2 -md sha512 -iter "$_kdf_iters" -salt -pass fd:3 "$@"
}
_dec_openssl () { _enc_openssl -d "$@"; }
_gpg_common () {
    gpg --compress-level 0 \
        --passphrase-fd 3 --pinentry-mode loopback --batch \
        --cipher-algo AES256 --digest-algo SHA512 \
        --s2k-cipher-algo AES256 --s2k-digest-algo SHA512 --s2k-mode 3 --s2k-count "$_kdf_iters" \
        "$@"
}
_enc_gpg () { _gpg_common --symmetric "$@"; }
_dec_gpg () { _gpg_common --decrypt "$@"; }
_encrypt () { _pepper="$1"; shift; _with_pw_on_fd3 "$_pepper" $_encrypt_func "$@"; }
_decrypt () { _pepper="$1"; shift; _with_pw_on_fd3 "$_pepper" $_decrypt_func "$@"; }
_encrypt_file () {
    _plain_path="$1"
    _enc_path="$2"
    mkdir -p "$ENC_REPO/$(dirname "$_enc_path")"
    is_binary () { git_plain show "HEAD:$_plain_path" | _is_binary_stream; }
    compress_if_text () { if is_binary; then cat; else gzip -cv2; fi; }
    git_plain show "HEAD:$_plain_path" |
        compress_if_text |
        _encrypt "$_plain_path" > "$ENC_REPO/$_enc_path"
}
_decrypt_file () {
    _enc_path="$1"
    _plain_path="$2"
    # Check if the plain file already exists
    if [ -f "$WORK_TREE/$_plain_path" ] && [ -z "${YES_OVERWRITE:-}" ]; then
        warn "WARNING: File '$WORK_TREE/$_plain_path' exists. Overwrite? [y/N]"
        read _choice
        case "$_choice" in [Yy]*) ;; *) warn "Skipping '$WORK_TREE/$_plain_path'"; return 0 ;; esac
    fi
    decrypted_tmpfile="$(_mktemp)"
    _decrypt "$_plain_path" < "$ENC_REPO/$_enc_path" > "$decrypted_tmpfile"
    mkdir -p "$(dirname "$WORK_TREE/$_plain_path")"
    if gzip -t "$decrypted_tmpfile" >/dev/null 2>&1; then
        gzip -dcv < "$decrypted_tmpfile"
    else
        cat "$decrypted_tmpfile"
    fi > "$WORK_TREE/$_plain_path"
    rm "$decrypted_tmpfile"
}
_decrypt_manifests () {
    status=0
    for file in "$ENC_REPO"/manifest/*; do
        fname="$(basename "$file")"
        _decrypt "" < "$file" | gzip -dc > "$PLAIN_REPO/manifest/$fname"
        if _is_binary_stream < "$PLAIN_REPO/manifest/$fname"; then
            warn "WARNING: Likely invalid decryption password for commit '$fname', or your manifest file contains binary paths."
            status=1
        fi
    done
    return $status
}
_with_pw_on_fd3 () {
    # Pass "$password$1" securely via an open file
    _pepper="$1"
    exec 3<<EOF
$PASSWORD$_pepper
EOF
    shift
    "$@"
    exec 3<&-
}


cmd_init () {
    # Init both dirs repos
    mkdir -p "$PLAIN_REPO" "$ENC_REPO"
    git -C "$PLAIN_REPO" init -b master --bare
    git -C "$ENC_REPO"   init -b master
    mkdir -p "$PLAIN_REPO/manifest" \
            "$ENC_REPO/manifest"
    # Don't pollute du
    rm "$PLAIN_REPO"/hooks/*.sample \
        "$ENC_REPO"/.git/hooks/*.sample

    # Configure
    email="$USER@$(hostname 2>/dev/null || cat /etc/hostname)"
    git_plain config user.name "$USER"
    git_plain config user.email "$email"
    git_plain config status.showUntrackedFiles no  # We don't care to see largely untracked $HOME  # XXX: remove this?
    git_plain config diff.renames "copies"  # Detect renames AND copies
    git_plain config diff.renameLimit 100000
    git_plain config core.excludesfile ""  # Don't look at $XDG_CONFIG_HOME/git/ignore
    git_plain config advice.addIgnoredFile true  # Warn user to use `add -f` on gitignored file
    git_enc config user.name "$USER"
    git_enc config user.email "$email"
    # All our files are strictly binary (encrypted)
    git_enc config core.bigFileThreshold 100
    git_enc config diff.renames "copies"
    git_enc config diff.renameLimit 100000
    git_enc config push.autoSetupRemote true
    git_enc config push.default upstream
    git_enc config fetch.parallel 4
    # Set up default gitignore
    case $- in *x*) xtrace_was_on=true; set +x ;; esac
    echo "$default_gitignore" > "$PLAIN_REPO/info/exclude"
    if [ "${xtrace_was_on:-}" ]; then set -x; fi

    echo '* -text -diff' >"$ENC_REPO/.git/info/attributes"
    # Encrypted repo is a sparse-checkout
    git_enc sparse-checkout set "manifest"
    git_enc sparse-checkout reapply
}


cmd_clone () {
    mkdir -p "$ENC_REPO"
    git clone --filter=blob:none --sparse -v "$1" "$ENC_REPO"
    cmd_init
    _ask_pw
    _decrypt_manifests
}


cmd_restore () {
    # Convert the encrypted commit messages back to plain repo commits
    if [ "$(git_plain ls-files)" ]; then
        if [ ! "${YES_OVERWRITE:-}" ]; then
            warn "WARNING: Plain repo in '$PLAIN_REPO' already restored (and possibly commited to). To overwrite, set \$YES_OVERWRITE=1."
            exit 1
        fi
        # Remove existing plain repo
        git_plain update-ref -d HEAD
        git_plain reflog expire --all --expire-unreachable=now
        git_plain gc --prune=now --aggressive
    fi
    temp_dir="$(_mktemp -d)"
    trap "rm -rf '$temp_dir'" INT HUP EXIT

    _ask_pw
    if [ "${1:-}" = "--squash" ]; then
        git_enc sparse-checkout disable
        git_enc ls-files "manifest/" |
            grep -RFhf- "$PLAIN_REPO/manifest" | sort -u |
            while IFS="$_tab" read -r _enc_path _plain_path; do
                WORK_TREE="$temp_dir" _decrypt_file "$_enc_path" "$_plain_path"
                WORK_TREE="$temp_dir" git_plain add "$_plain_path"
            done
        if ! WORK_TREE="$temp_dir" git_plain diff --staged --quiet; then
            WORK_TREE="$temp_dir" git_plain commit -m "Restore '$1' at $(date '+%Y-%m-%d %H:%M:%S%z')"
        fi
    else
        git_enc log --reverse --pretty='%H' |
            while IFS= read -r _enc_commit; do
                git_enc show --name-only --pretty=format: "$_enc_commit" |
                    git_enc sparse-checkout set --stdin
                git_enc sparse-checkout reapply

                # Decrypt and stage files from this commit into temp_dir
                plain_commit="$(git_enc show --name-only --pretty=format: "$_enc_commit" -- "manifest/" |
                                cut -d/ -f2)"
                while IFS="$_tab" read -r _enc_path _plain_path; do
                    WORK_TREE="$temp_dir" _decrypt_file "$_enc_path" "$_plain_path"
                    WORK_TREE="$temp_dir" git_plain add "$_plain_path"
                done < "$PLAIN_REPO/manifest/$plain_commit"

                # Commit the changes to the plain repo
                _msg="$(git_enc show -s --format='%B' "$_enc_commit" |
                        _decrypt "" $_armor_flags |
                        gzip -dc)"
                _date="$(git_enc show -s --format='%ai' "$_enc_commit")"
                _author="$(git_enc show -s --format='%an <%ae>' "$_enc_commit")"
                if ! WORK_TREE="$temp_dir" git_plain diff --staged --quiet; then
                    WORK_TREE="$temp_dir" git_plain commit --no-gpg-sign -m "$_msg" --date "$_date" --author "$_author"
                fi
            done
    fi

    cmd_gc
}


_parallelize () {
    n_threads="${N_JOBS:-$1}"  # Number of threads to keep consuming stdin
    n_vars="$2"  # Number of TAB-separated values per stdin line
    shift 2
    _func="$1"  # Func to pass args and values to
    terminate=
    while [ ! "$terminate" ]; do
        pids=
        for _i in $(seq "$n_threads"); do
            # Read n_vars variables, splitting by TAB
            if ! eval "IFS='$_tab' read -r $(seq -s' ' -f 'var%.0f' "$n_vars")"; then
                terminate=1
                break
            fi
            # Call function with args and variables in background
            # shellcheck disable=SC2016,SC2294
            { eval "$@" $(seq -s' ' -f '"$var%.0f"' "$n_vars"); } &
            pids="$pids $!"
        done
        # Wait on all spawned jobs; transferring their exit status to ours
        for pid in $pids; do wait "$pid"; done
    done
}


_commit_encrypt_one () (
    _status="$(echo "$1" | cut -c1)"  # "R100", "C100", ...
    # Reference: https://git-scm.com/docs/git-status#_output
    if [ "$_status" = 'A' ] || [ "$_status" = 'M' ]; then  # newly added / modified
        _path="$2"
    elif [ "$_status" = 'R' ] || [ "$_status" = 'C' ]; then  # renamed / copied
        _path="$(echo "$2" | cut -f2)"
    elif [ "$_status" = 'T' ]; then  # typechange (regular file, symlink or submodule)
        # TODO: If readlink -f is in repo, simply commit a link to it?
        #  Requires the same kind of check on decode side
        # TODO: Assert not submodule :)
        # Currently warn on anything but a file
        if [ ! -f "$2" ]; then
            warn "WARNING: Only regular files supported. A copy of '$2' will be made."
        fi
        _path="$2"
    else
        [ "$_status" = 'D' ] || [ "$_status" = 'U' ] || {
            warn "ERROR: Unknown git status '$1' for '$2' (known types: AMDRC)"
        }
        return 0
    fi
    _encrypt_file "$_path" "$(_encrypted_path "$_path")"
)


_commit_delete_enc_path () {
    git_enc lfs untrack "$1" || true  # Ok if Git LFS is not used
    git_enc rm -f --sparse "$1"
}


cmd_commit () {
    # Commit to plain repo
    git_plain commit --message "myba backup $(date '+%Y-%m-%d %H:%M:%S')" --verbose "$@"

    # Encrypt and stage encrypted files
    _ask_pw
    manifest_path="manifest/$(git_plain rev-parse HEAD)"
    git_plain show --name-status --pretty=format: HEAD |
        _parallelize 8 2 _commit_encrypt_one
    # Do git stuff here and now, single process, avoiding errors like:
    #     fatal: Unable to create .../_encrypted/.git/index.lock': File exists
    git_plain show --name-status --pretty=format: HEAD |
        while IFS="$_tab" read -r _status _path; do
            _status="$(echo "$_status" | cut -c1)"
            # Handle statuses
            # Reference: https://git-scm.com/docs/git-status#_output
            if [ "$_status" = 'D' ]; then
                _commit_delete_enc_path "$(_encrypted_path "$_path")"
            elif [ "$_status" = 'R' ]; then  # renamed
                _path_old="$(echo "$_path" | cut -f1)"
                _commit_delete_enc_path "$(_encrypted_path "$_path_old")"
                _path="$(echo "$_path" | cut -f2)"
            elif [ "$_status" = 'C' ]; then  # copied
                _path="$(echo "$_path" | cut -f2)"
            fi
            # Add new encrypted file
            if [ "$_status" = 'A' ] || [ "$_status" = 'M' ] ||
                    [ "$_status" = 'R' ] || [ "$_status" = 'C' ]; then
                _enc_path="$(_encrypted_path "$_path")"
                # If file larger than 40 MB, configure Git LFS
                if [ "$(_file_size "$ENC_REPO/$_enc_path")" -gt $((40 * 1024 * 1024)) ]; then
                    git_enc lfs track --filename "$_enc_path"
                fi
                git_enc add -v --sparse "$_enc_path"
                echo "$_enc_path$_tab$_path" >> "$PLAIN_REPO/$manifest_path"
            fi
        done

    # If first commit, add self
    if ! git_enc rev-parse HEAD 2>/dev/null; then
        _self="$(command -v "$0" 2>/dev/null || echo "$0")"
        cp "$_self" "$ENC_REPO/$(basename "$_self")"
        git_enc add --sparse "$(basename "$_self")"
    fi

    # Stage new manifest
    gzip -c2 "$PLAIN_REPO/$manifest_path" |
        _encrypt "" > "$ENC_REPO/$manifest_path"
    git_enc add --sparse "$manifest_path"

    # Commit to encrypted repo
    git_enc status --short
    git_enc commit -m "$(
        git_plain show --format='%B' --name-status |
            gzip -c9 |
            _encrypt "" $_armor_flags)"
}


cmd_checkout() {
    if [ $# -eq 0 ]; then warn 'Nothing to checkout'; exit 1; fi
    # If a commit hash is provided, checkout that commit in either repo
    if git_plain rev-parse --verify "$1^{commit}" >/dev/null 2>&1; then
        git_plain checkout "$1"
    elif git_enc rev-parse --verify "$1^{commit}" >/dev/null 2>&1; then
        git_enc sparse-checkout set "manifest"
        git_enc sparse-checkout reapply
        git_enc checkout "$1"
        _ask_pw
        _decrypt_manifests
    else
        # Otherwise, assume the arguments are paths to files/directories
        working_manifest="$PLAIN_REPO/working_manifest"
        for pattern in "$@"; do
            grep -REIh "$_tab$pattern"'($|/)' "$PLAIN_REPO/manifest"
        done | sort -u > "$working_manifest"

        cut -f1 "$working_manifest" |
            git_enc sparse-checkout set --stdin
        git_enc sparse-checkout add "manifest"
        git_enc sparse-checkout reapply

        _ask_pw
        _parallelize 8 2 _checkout_file < "$working_manifest"
        rm "$working_manifest"
    fi
}


_checkout_file () {
    _enc_path="$1"
    _plain_path="$2"
    if [ -f "$ENC_REPO/$_enc_path" ]; then
        _decrypt_file "$_enc_path" "$_plain_path"
    else
        echo "INFO: File '$_plain_path' committed but since removed."
    fi
}


cmd_rm() {
    _is_error=
    for _path in "$@"; do
        if ! git_plain ls-files --error-unmatch "$_path" >/dev/null 2>&1; then
            echo "$0: Error: '$_path' is not being tracked."
            _is_error=1
            continue
        fi
        git_plain rm --cached "$_path"  # Leave worktree copy alone

        # NOTE: The rest (encrypted repo) is handled in cmd_commit
    done
    return $_is_error
}


cmd_remote () {
    git_enc remote "$@";
    if [ "$1" = 'add' ]; then
        # Ideally, this would reside in cmd_init, but then
        # `git remote add` complains 'error: remote origin already exists'
        git_enc config "remote.$2.promisor" true
        git_enc config "remote.$2.partialclonefilter" "blob:none"
    fi
}


cmd_push () {
    if [ $# -eq 0 ]; then
        # With no args, push to all remotes
        git_enc remote show -n |
            while read _origin; do
                git_enc push --verbose --all "$_origin"
            done
    else
        git_enc push --verbose --all "$@"
    fi
    git_enc fetch --refetch --all --verbose --no-write-fetch-head

    # Remove redundant files including just-pushed packs
    sleep .2  # Fix "fatal: gc is already running on machine"
    cmd_gc
}

cmd_gc () {
    # Reduce disk usage by removing encrypted repo's blobs
    git_enc sparse-checkout set "manifest"
    git_enc sparse-checkout reapply

    # Outright rm packs for which promisor nodes exist
    for file in "$ENC_REPO/.git/objects/pack"/pack-*.pack; do
        touch "${file%.pack}.promisor"
        rm -f "${file%.pack}.pack" \
            "${file%.pack}.idx"
    done
}


# Simple passthrough commands
cmd_add () { git_plain add "$@"; }
cmd_diff () { git_plain diff "$@"; }
cmd_pull () { git_enc pull "$@"; _ask_pw; _decrypt_manifests; }
cmd_log () {
    git_plain log \
        --pretty="%C(yellow)%h%C(red) %cd%C(cyan) %s%C(reset)" \
        --date=short --name-status "$@"
}

verbose () {
    echo "$0: $*" >&2
    case "${VERBOSE:-}" in
    '') "$@"; ;;
    *) set -x; "$@"; set +x; ;;
    esac
    echo "$0: $1 done ok" >&2
}


default_gitignore='
# Compiled source
build/
_build/
*.py[cod]
*.[oa]
*.la
*.obj
*.[kms]o
*.so.*
*.dylib
*.elf
*.lib
*.dll
*.class
*.out

# Other VCS
.git/

# Ignore Python
.venv/
venv/
python*/site-packages/
*.py[cod]
__pycache__/
.eggs/
*.egg/
*.egg-info
dist/*.tar.gz
dist/*.zip
dist/*.whl

# Ignore JS
node_modules/
.npm/
.eslintcache
.yarn/
.grunt/

# Docs
htmlcov/
.tox/
.coverage/
.coverage.*/
coverage.xml
.hypothesis/
.mypy_cache/

# IDEs and editors
.idea/*
.vscode/*

# Temporary & logs
*.cache
*.tmp
tmp/
*.bak
*.old
*.pid
*.lock
*~
logs
*.log

# OS
.DS_Store
Thumbs.db
'


# Main:
cmd=
if [ $# -gt 0 ]; then cmd="$1"; shift; fi

case "$cmd" in
    init) verbose cmd_init ;;
    add) verbose cmd_add "$@" ;;
    rm) verbose cmd_rm "$@" ;;
    commit) verbose cmd_commit "$@" ;;
    remote) verbose cmd_remote "$@" ;;
    push) verbose cmd_push "$@" ;;
    pull) verbose cmd_pull "$@" ;;
    clone) verbose cmd_clone "$@" ;;
    restore) verbose cmd_restore "$@" ;;
    diff) verbose cmd_diff "$@" ;;
    log) verbose cmd_log "$@" ;;
    checkout) verbose cmd_checkout "$@" ;;
    gc) verbose cmd_gc "$@" ;;
    git) verbose git_plain "$@" ;;
    git_enc) verbose git_enc "$@" ;;
    *) usage ;;
esac
