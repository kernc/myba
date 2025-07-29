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

# shellcheck disable=SC2086,SC2162,SC3045

set -eu

# Configuration via env vars
WORK_TREE="${WORK_TREE:-${HOME:-~}}"
PLAIN_REPO="${PLAIN_REPO:-$WORK_TREE/.myba}"
ENC_REPO="$PLAIN_REPO/_encrypted"
#PASSWORD=  # Replace with your encryption password or if null, read stdin
GIT_LFS_THRESH="${GIT_LFS_THRESH:-$((40 * 1024 * 1024))}"  # 50 MB limit on GitHub/GitLab


############################################################################################

mybabackup_dir='.mybabackup'

usage () {
    echo "Usage: $0 <subcommand> [options]"
    echo "Subcommands:"
    echo "  init                  Initialize repos in \$WORK_TREE (default: \$HOME)"
    echo "  add [OPTS] PATH...    Stage files for backup/version tracking"
    echo "  rm PATH...            Stage-remove files from future backups/version control"
    echo "  commit [OPTS]         Commit staged changes of tracked files as a snapshot"
    echo "  push [REMOTE]         Push encrypted repo to remote repo(s) (default: all)"
    echo "  pull [REMOTE]         Pull encrypted commits from a promisor remote"
    echo "  clone REPO_URL        Clone an encrypted repo and init from it"
    echo "  remote CMD [OPTS]     Manage remotes of the encrypted repo"
    echo "  decrypt [--squash]    Reconstruct plain repo commits from encrypted commits"
    echo "  reencrypt             Reencrypt plain repo commits with a new password"
    echo "  diff [OPTS]           Compare changes between plain repo revisions"
    echo "  log [OPTS]            Show commit log of the plain repo"
    echo "  status [OPTS]         Show git status of the plain repo"
    echo "  ls-files [OPTS]       Show current backup files"
    echo "  largest               List current backup files by file size, descending"
    echo "  checkout PATH...      Sparse-checkout and decrypt files into \$WORK_TREE"
    echo "  checkout COMMIT       Switch files to a commit of plain or encrypted repo"
    echo "  gc                    Garbage collect, remove synced encrypted packs"
    echo "  git CMD [OPTS]        Inspect/execute raw git commands inside plain repo"
    echo "  git_enc CMD [OPTS]    Inspect/execute raw git commands inside encrypted repo"
    echo
    echo 'PLAIN repo  <--encryption-->  ENCRYPTED repo  <--synced with-->  git REMOTE'
    echo
    echo 'Env vars: WORK_TREE, PLAIN_REPO, PASSWORD, USE_GPG, VERBOSE, YES_OVERWRITE,'
    echo '          GIT_LFS_THRESH (in bytes)'
    echo 'For a full list and info, see: https://kernc.github.io/myba/'
    exit 1
}

warn () { echo "$(basename "$0" .sh): $*" >&2; }

_tab="$(printf '\t')"

git_plain () { git --work-tree="$WORK_TREE" --git-dir="$PLAIN_REPO" "$@"; }
_git_plain_nonbare () { git -C "$PLAIN_REPO" "$@"; }
git_enc () { git -C "$ENC_REPO" "$@"; }

_debug_git () { GIT_TRACE_PACK_ACCESS=1 GIT_TRACE=1 "$@"; }

_git_enc_sparse_checkout_files () {
    # sparse-checkout cone requires dirs
    # TODO: debug why upon decrypt receiving the whole
    sed -E 's,[^/]+$,,' |
        sort -u |
        _debug_git git_enc sparse-checkout set --stdin;
    git_enc sparse-checkout list
}

_is_binary_stream () { dd bs=8192 count=1 status=none | LC_ALL=C tr -dc '\000' | LC_ALL=C grep -qa .; }
_mktemp () { mktemp -t "$(basename "$0" .sh)-XXXXXXX" "$@"; }
_file_size () { stat -c%s "$@" 2>/dev/null || stat -f%z "$@"; }
_read_vars () {
    # https://unix.stackexchange.com/questions/418060/read-a-line-oriented-file-which-may-not-end-with-a-newline/418066#418066
    read -r "$@" || [ "$(eval echo '$'"$1")" ];
}

_ask_pw () {
    if [ -z "${PASSWORD+1}" ]; then
        stty -echo
        {
            IFS= read -p "Enter encryption PASSWORD=: " -r PASSWORD
            echo
            (
                IFS= read -p "Repeat: " -r PASSWORD2
                [ "$PASSWORD" = "$PASSWORD2" ] || { warn 'ERROR: Password mismatch!'; exit 1; }
            )
        } < /dev/tty
        stty echo
    fi

    # Set up encryption via OpenSSL
    _encrypt_func=_enc_openssl
    _decrypt_func=_dec_openssl
    _kdf_iters="${KDF_ITERS:-321731}"
    # Set up encryption via GPG
    if [ "${USE_GPG:+1}" ]; then
        _encrypt_func=_enc_gpg
        _decrypt_func=_dec_gpg
        _kdf_iters="${KDF_ITERS:-32111731}"  # OpenSSL and GPG use different KDF algos
    fi
}
_encrypted_path () (
    set +x  # Avoid terminal noise and secret-spilling in this subshell (Notice () parenthesis)
    echo "$1$PASSWORD$1$PASSWORD" |
        shasum -a512 | cut -d' ' -f1 |
        sed -E 's,(..)(..)(.*),d/\1/\2/\3,'
)

_openssl_common () { openssl enc -aes-256-ctr -pbkdf2 -md sha512 -iter "$_kdf_iters" -salt -pass fd:3 "$@"; }
_enc_openssl () { _openssl_common | tail -c +9 -f; }  # Remove "Salted__"
_dec_openssl () { { printf 'Salted__'; cat; } | _openssl_common -d "$@"; }
_gpg_common () {
    gpg --compress-level 0 \
        --passphrase-fd 3 --pinentry-mode loopback --batch \
        --no-tty --no-greeting --no-autostart --no-random-seed-file --no-keyring \
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
_bind_tty_fd7 () { sh -c ':>/dev/tty' 2>/dev/null && exec 7< /dev/tty || exec 7< /dev/null; }  # Fd 7 used in _decrypt_file
_decrypt_file () {
    _enc_path="$1"
    _plain_path="$2"
    # Check if the plain file already exists
    [ ! -d "/proc/$$" ] || [ -e "/proc/$$/fd/7" ]  # Assert fd-7 is available
    if [ -f "$WORK_TREE/$_plain_path" ] && [ -z "${YES_OVERWRITE:-}" ]; then
        warn "WARNING: File '$WORK_TREE/$_plain_path' exists. Overwrite? [y/N]"
        read _choice <&7
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
            rm "$PLAIN_REPO/manifest/$fname"
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
    git_plain config advice.detachedHead false  # Subprocedures do detached-head checkouts
    git_plain config init.defaultBranch master
    git_enc config user.name "$USER"
    git_enc config user.email "$email"
    # All our files are strictly binary (encrypted)
    git_enc config core.bigFileThreshold 100
    git_enc config diff.renames "copies"
    git_enc config diff.renameLimit 100000
    git_enc config push.autoSetupRemote true
    git_enc config push.default current
    git_enc config push.followTags true
    git_enc config fetch.parallel 4
    git_enc config advice.detachedHead false  # Subprocedures do detached-head checkouts
    git_enc config init.defaultBranch master
    # Set up default gitignore
    echo "$default_gitignore" > "$PLAIN_REPO/info/exclude"

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


cmd_decrypt () {
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
    # shellcheck disable=SC2064
    trap "rm -rf \"$temp_dir\"" INT HUP TERM EXIT

    have_commitable_changes () { WORK_TREE="$temp_dir" git_plain diff --staged --quiet; }
    read_decrypt_and_git_add_files () {
        while IFS="$_tab" _read_vars _enc_path _plain_path; do
            WORK_TREE="$temp_dir" _decrypt_file "$_enc_path" "$_plain_path"
            WORK_TREE="$temp_dir" git_plain add -vf "$_plain_path"  # -f to ignore .gitignore
        done
    }

    _ask_pw
    _bind_tty_fd7
    if [ "${1:-}" = "--squash" ]; then
        git_enc sparse-checkout disable
        git_enc ls-files "manifest/" |
            grep -RFhf- "$PLAIN_REPO/manifest" |
            sort -u |
            read_decrypt_and_git_add_files
        if ! have_commitable_changes; then
            WORK_TREE="$temp_dir" git_plain commit -m "Restore '$1' at $(date '+%Y-%m-%d %H:%M:%S%z')"
        fi
    else
        quiet _trap_append "git_enc checkout --force master" INT HUP TERM EXIT
        git_enc rev-list --reverse master |
            while IFS= _read_vars _enc_commit; do
                # shellcheck disable=SC2154
                git_enc checkout --force "$_enc_commit"
                git_enc show --name-only --pretty=format: "$_enc_commit" |
                    _git_enc_sparse_checkout_files
                git_enc sparse-checkout reapply

                # Decrypt and stage files from this commit into temp_dir
                plain_commit="$(git_enc show --name-only --pretty=format: "$_enc_commit" -- "manifest/" |
                                cut -d/ -f2)"
                read_decrypt_and_git_add_files < "$PLAIN_REPO/manifest/$plain_commit"

                # Commit the changes to the plain repo
                _msg="$(git_enc show -s --format='%B' "$_enc_commit" |
                        base64 -d | _decrypt "" | gzip -dc)"
                _date="$(git_enc show -s --format='%ai' "$_enc_commit")"
                _author="$(git_enc show -s --format='%an <%ae>' "$_enc_commit")"
                if ! have_commitable_changes; then
                    WORK_TREE="$temp_dir" git_plain commit --no-gpg-sign -m "$_msg" --date "$_date" --author "$_author"
                fi
            done
    fi

    cmd_gc
}


cmd_reencrypt() {
    _ask_pw

    # Remove, but not squash, current encrypted files
    git_enc sparse-checkout disable
    enc_files="$(git_enc ls-files | grep -v "^${0##*/}$" || true)"
    if [ "$enc_files" ]; then
        # shellcheck disable=SC2046
        git_enc rm $enc_files
        git_enc commit -m 'reencrypt'
    fi

    mkdir -p "$ENC_REPO/manifest"

    temp_dir="$(_mktemp -d)"
    # shellcheck disable=SC2064
    quiet _trap_append "rm -rvf \"$temp_dir\"" INT HUP TERM EXIT

    WORK_TREE="$temp_dir"  # Don't switcheroo "live" config files!

    quiet _trap_append "git_plain checkout --force master" INT HUP TERM EXIT
    # Loop through plain commit hashes and checkout & cmd_commit
    git_plain rev-list --reverse master |
        while _read_vars commit_hash; do
            # shellcheck disable=SC2154
            git_plain checkout "$commit_hash"
            _encrypt_commit_plain_head_files

            # ???
#            manifest_path="manifest/$commit_hash"
#            # Process only if manifest exists
#            # Maybe it failed `decrypt` for some commits
#            if [ -f "$PLAIN_REPO/$manifest_path" ]; then
#                # Decrypt current manifest with old password
#                _decrypt "" < "$ENC_REPO/$manifest" | gzip -dc > "$PLAIN_REPO/$manifest_path".tmp
#                # Temporarily switch to new password and reencrypt
#                old_pw=$PASSWORD
#                PASSWORD="$NPW"
#                gzip -c2 "$PLAIN_REPO/$m".tmp | _encrypt "" > "$ENC_REPO/$m".new
#                mv "$ENC_REPO/$m".new "$ENC_REPO/$m"
#                PASSWORD=$old_pw
#                rm "$PLAIN_REPO/$m".tmp
#            fi
        done

    echo "Re-encryption complete."
}


_trap_append() {
    new="$1"
    shift
    for sig; do
        old="$(trap | sed -nE "s/^trap -- '(.*)' $sig$/\1/p")"
        [ "$old" ] && cmd="$new; $old" || cmd="$new"
        # shellcheck disable=SC2064
        trap "$cmd" "$sig"
    done
}


_parallelize () {
    n_threads="${N_JOBS:-$1}"  # Number of threads to keep consuming stdin
    [ $n_threads -gt 0 ] || n_threads="$(getconf _NPROCESSORS_ONLN || getconf NPROCESSORS_ONLN)"
    n_vars="$2"  # Number of TAB-separated values per stdin line
    _func="$3"  # Func to pass args and values to
    shift 3

    tmpdir="$PLAIN_REPO/parallelize.$$"
    mkdir -p "$tmpdir"
    quiet _trap_append "rm -rfv \"$tmpdir\"" INT HUP TERM EXIT
    # Init a FIFO semaphore
    fifo="$tmpdir/semaphore"
    mkfifo "$fifo"
    exec 3<>"$fifo"
    printf "%${n_threads}s" | tr " " "\n" >&3  # n_threads tokens

    pids=
    _track_job () { pids="$pids $!"; }
    # Read n_vars variables per line, splitting by TAB
    while eval "IFS='$_tab' read -r $(seq -s' ' -f 'var%.0f' "$n_vars")" || [ "$var1" ]; do
        read -r _ <&3  # Acquire semaphore or block
        # Call function with args and variables in background
        {
            # shellcheck disable=SC2016,SC2294
            eval $_func "$@" $(seq -s' ' -f '"$var%.0f"' "$n_vars")
            # Release semaphore
            # XXX: For some reason doesn't work with fd3 (not inherited)?
            exec 4>"$fifo"
            echo >&4
            exec 4>&-
        } 1>"$tmpdir/out" 2>"$tmpdir/err" &
        quiet _track_job
        # Keep pid-based references to stdout/stderr
        while [ ! -f "$tmpdir/out" ] && [ ! -f "$tmpdir/err" ]; do sleep .01; done
        mv "$tmpdir/out" "$tmpdir/out.$!"
        mv "$tmpdir/err" "$tmpdir/err.$!"
    done
    # Wait on all spawned jobs; transferring their exit status to ours
    status=0
    for pid in $pids; do
        if ! wait "$pid"; then status=1; fi
        cat "$tmpdir/out.$pid"
        cat "$tmpdir/err.$pid" >&2
    done
    if [ $status -ne 0 ]; then exit 1; fi
}


# shellcheck disable=SC2030
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
            warn "WARNING: Only regular files supported; no links etc. A duplicate of '$2' will be commited."
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
    git_enc lfs untrack "$1" &&
        git_enc add -vf --sparse '.gitattributes' ||
        true  # Passthrough ok if Git LFS is not used
    git_enc rm -f --ignore-unmatch --sparse "$1"
}

_update_added_dirs () {
    # Update .mybabackup dirs
    backup_dirs="$(_git_plain_nonbare ls-files |
                  grep "/${mybabackup_dir}[\"']?\$" |
                  sed -E "s,/$mybabackup_dir([\"']?)\$,\1," |
                  sort -u)"
    if [ "$backup_dirs" ]; then
        git_plain add -vf "$backup_dirs"
    fi
}

cmd_commit () {
    _update_added_dirs

    # Commit to plain repo
    git_plain commit --verbose "$@" --message "myba backup $(date '+%Y-%m-%d %H:%M:%S')"

    _ask_pw
    _encrypt_commit_plain_head_files
}


# shellcheck disable=SC2031
_encrypt_commit_plain_head_files () {
    # Encrypt and stage encrypted files
    git_plain show --name-status --pretty=format: HEAD |
        _parallelize 0 2 _commit_encrypt_one
    # Do git stuff here and now, single process, avoiding errors like:
    #     fatal: Unable to create .../_encrypted/.git/index.lock': File exists
    manifest_path="manifest/$(git_plain rev-parse HEAD)"
    : > "$PLAIN_REPO/$manifest_path"
    git_plain show --name-status --pretty=format: HEAD | {
        files_to_add=
        _add_file () { files_to_add="$files_to_add $_enc_path"; }
        while IFS="$_tab" _read_vars _status _path; do
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
                # If file larger than threshold, configure Git LFS
                if [ "$(_file_size "$ENC_REPO/$_enc_path")" -gt $GIT_LFS_THRESH ]; then
                    git_enc lfs track --filename "$_enc_path"
                    git_enc add -vf --sparse '.gitattributes'
                fi
                quiet _add_file
                echo "$_enc_path$_tab$_path" >> "$PLAIN_REPO/$manifest_path"
            fi
        done
        if [ "$files_to_add" ]; then
            # FIXME: Prevent git-add doing a git-fetch on every promisor remote for every file.
            #   A speed up of ~1s/file is achieved. Can we do it in some cleaner way?
            _cfg="$ENC_REPO/.git/config"
            cp "$_cfg" "$_cfg.$$"
            _restore_removed_remotes () { mv "$_cfg.$$" "$_cfg" || true; }
            quiet _trap_append _restore_removed_remotes INT HUP TERM EXIT
            for remote in $(git_enc remote); do git_enc remote rm $remote; done

            git_enc add -vf --sparse -- $files_to_add

            _restore_removed_remotes
        fi
    }

    # If first commit, add self
    if ! git_enc rev-parse master 2>/dev/null; then
        _self="$(command -v "$0" 2>/dev/null || echo "$0")"
        cp "$_self" "$ENC_REPO/$(basename "$_self")"
        git_enc add -vf --sparse "$(basename "$_self")"
    fi

    # Stage new manifest
    if [ "$(_file_size "$PLAIN_REPO/$manifest_path")" -gt 0 ]; then
        gzip -c2 "$PLAIN_REPO/$manifest_path" |
            _encrypt "" > "$ENC_REPO/$manifest_path"
        git_enc add -vf --sparse "$manifest_path"
    else
        rm "$PLAIN_REPO/$manifest_path"
    fi

    # Commit to encrypted repo
    git_enc status --short
    git_enc commit -m "$(
        git_plain show --format='%B' --name-status |
            gzip -c9 | _encrypt "" | { base64 -w 0 || base64; })"
}


cmd_checkout() {
    if [ $# -eq 0 ]; then warn "Usage: ${0##*/} checkout (COMMIT | FILE...)"; exit 1; fi
    # If a commit hash is provided, checkout that commit in either repo
    if git_plain rev-parse --verify "$1^{commit}" >/dev/null 2>&1; then
        git_plain checkout "$@"
    elif git_enc rev-parse --verify "$1^{commit}" >/dev/null 2>&1; then
        git_enc sparse-checkout set "manifest"
        git_enc sparse-checkout reapply
        git_enc checkout "$@"
        _ask_pw
        _decrypt_manifests
    else
        # Otherwise, assume the arguments are paths to files/directories
        working_manifest="$PLAIN_REPO/checkout.$$"
        _trap_append "rm -v \"$working_manifest\"" INT HUP TERM EXIT
        for file in "$@"; do
            grep -REIh "$_tab$file"'($|/)' "$PLAIN_REPO/manifest"
        done | sort -u > "$working_manifest"

        {
            echo 'manifest/'
            cut -f1 "$working_manifest"
        } | _git_enc_sparse_checkout_files
        git_enc sparse-checkout reapply

        _ask_pw
        _bind_tty_fd7
        _parallelize 0 2 _checkout_file < "$working_manifest"
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
            while _read_vars _origin; do
                # shellcheck disable=SC2154
                git_enc push --verbose "$_origin" master
            done
    else
        git_enc push --verbose "$@"
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


cmd_add () {
    git_plain add -v "$@"

    # Mark directories as recursively tracked
    for dir in "$@"; do
        if [ -d "$dir" ]; then
            touch "$dir/$mybabackup_dir"
            git_plain add -vf "$dir/$mybabackup_dir"
        fi
    done
}


cmd_largest () {
    git_plain ls-tree --full-tree -r -t --full-name --format='%(objectsize:padded)%x09%(path)' HEAD |
        sort -r -n "$@" |
        grep -v '^ *-' |
        { numfmt --to=iec-i --suffix=B || gnumfmt --to=iec-i --suffix=B; }
}


# Simple passthrough commands
cmd_diff () { git_plain diff "$@"; }
cmd_pull () { git_enc pull "$@"; _ask_pw; _decrypt_manifests; }
cmd_status () { _update_added_dirs; git_plain status "$@"; }
cmd_lsfiles () { _git_plain_nonbare ls-files "$@"; }  # https://stackoverflow.com/questions/25906192/git-ls-files-in-bare-repository
cmd_log () {
    git_plain log \
        --pretty="%C(yellow)%h%C(red) %cd%C(cyan) %s%C(reset)" \
        --date=short --name-status "$@"
}

verbose () {
    # xtrace prompt for sh, bash, zsh
    PS4="$(
        if [ "${LINENO:-}" ] && [ "${BASH_VERSION:-}" ]; then lineno=':$LINENO>'; fi
        printf "\033[34;40;1m+%s${lineno:-}\033[0m " "$0"
    )"
    export PS4
    echo "$0: $*" >&2
    case "${VERBOSE:-}" in
    '') "$@"; ;;
    *) set -x; "$@"; set +x; ;;
    esac
    echo "$0: $1 done ok" >&2
}
quiet () {
    case $- in *x*) set +x; xtrace_on=1 ;; *) xtrace_on= ;; esac
    "$@"
    if [ "$xtrace_on" ]; then set -x; fi
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
!.git/config

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
    decrypt) verbose cmd_decrypt "$@" ;;
    reencrypt) verbose cmd_reencrypt "$@" ;;
    diff) verbose cmd_diff "$@" ;;
    log) verbose cmd_log "$@" ;;
    status) verbose cmd_status "$@" ;;
    ls-files) verbose cmd_lsfiles "$@" ;;
    largest) verbose cmd_largest "$@" ;;
    checkout) verbose cmd_checkout "$@" ;;
    gc) verbose cmd_gc "$@" ;;
    git_enc) verbose git_enc "$@" ;;
    git)
        # Handle buggy ls-files in bare plain repo
        # https://stackoverflow.com/questions/25906192/git-ls-files-in-bare-repository
        if [ "${1:-}" = "ls-files" ]; then
            shift
            verbose _git_plain_nonbare ls-files "$@"
        else
            verbose git_plain "$@"
        fi
        ;;
    *) usage ;;
esac
