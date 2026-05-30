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
    echo 'Subcommands:'
    echo '  init [OPTS]           Initialize repos in $WORK_TREE (default: $HOME)'
    echo '  clone REPO_URL        Clone an encrypted repo and init from it'
    echo '  remote CMD [OPTS]     Manage git remotes of the encrypted repo'
    echo '  switch [BRANCH]       Switch orphan branches (vaults) on both repos'
    echo
    echo '  add [OPTS] PATH...    Stage files for backup / version tracking'
    echo '  rm PATH...            Stage-remove files from future backups / versioning'
    echo '  commit [OPTS]         Commit staged changes of tracked files as a snapshot'
    echo '  checkout PATH...      Sparse-checkout and decrypt files into $WORK_TREE'
    echo '  checkout COMMIT       Switch files to a commit of plain or encrypted repo'
    echo
    echo '  status [OPTS]         Show git status of the plain repo'
    echo '  diff [OPTS]           Compare changes between plain repo revisions'
    echo '  log [OPTS]            Show commit log of the plain repo'
    echo '  ls-files [OPTS]       Show current backup files in the plain repo'
    echo '  largest [OPTS]        List (ls-tree) backup files by file size, descending'
    echo
    echo '  push [OPTS]           Push encrypted repo to remote repo(s) (default: all)'
    echo '  pull [OPTS]           Pull encrypted commits from a promisor remote'
    echo '  decrypt [--squash]    Reconstruct plain repo commits from the encrypted'
    echo '  reencrypt             Reencrypt plain repo commits with a new password'
    echo '  gc                    Remove synced encrypted packs'
    echo
    echo '  pw [check]            Secure password input. Usage: PASSWORD="$(myba pw)"'
    echo '  git CMD [OPTS]        Exec raw git commands inside local plain repo'
    echo '  git_enc CMD [OPTS]    Exec raw git commands inside synced encrypted repo'
    echo
    echo 'PLAIN repo  <--encryption-->  ENCRYPTED repo  <--synced with-->  git REMOTE'
    echo
    echo 'Env vars: WORK_TREE, PLAIN_REPO, PASSWORD | SECURITY_TOKEN, USE_GPG, VERBOSE,'
    echo '          YES_OVERWRITE, GIT_LFS_THRESH (in bytes)'
    echo 'For a full list and info, see: https://kernc.github.io/myba/?utm_source=app'
    exit 1
}

warn () { echo "${0##*/}: $*" >&2; }

_tab="$(printf '\t')"

git_plain () { git --work-tree="$WORK_TREE" --git-dir="$PLAIN_REPO" "$@"; }
_git_plain_nonbare () { git -C "$PLAIN_REPO" "$@"; }
git_enc () { git -C "$ENC_REPO" "$@"; }

_debug_git () { GIT_TRACE_PACK_ACCESS=1 GIT_TRACE=1 "$@"; }

_git_enc_sparse_checkout_files () {
    # TODO: debug why upon decrypt receiving the whole
    {
        echo 'manifest/'
        echo 'd/'
        # stdin is assumed ls-files, sparse-checkout cone requires dirs
        sed -E 's,[^/]+$,,'
    } | sort -u | _debug_git git_enc sparse-checkout set --stdin
    git_enc sparse-checkout reapply
}

_is_binary_stream () { head -c 8192 | LC_ALL=C tr -dc '\000' | LC_ALL=C grep -qa .; }
_gzip_strip_header () { tail -c +11; }
_gzip_add_header () { printf '\037\213\010\000\000\000\000\000\000\003'; cat; }
_mktemp () { mktemp -t "${0##*/}-$$-XXXXXXX" "$@"; }
_rm_tmp () { _trap_append "rm -rf \"$1\"" INT HUP TERM EXIT; }
_file_size () { stat -c%s "$@" 2>/dev/null || stat -f%z "$@"; }
_read_vars () {
    # https://unix.stackexchange.com/questions/418060/read-a-line-oriented-file-which-may-not-end-with-a-newline/418066#418066
    read -r "$@" || [ "$(eval echo '$'"$1")" ];
}

cmd_pw () {
    if [ "${1-}" = 'check' ]; then _cmd_pw_check; return; fi
    stty -echo
    {
        IFS= read -p "Enter encryption PASSWORD=: " -r PASSWORD && echo >&2
        (
            IFS= read -p "Repeat: " -r PASSWORD2 && echo >&2
            [ "$PASSWORD" = "$PASSWORD2" ] || { warn 'ERROR: Password mismatch!'; exit 1; }
        )
    } </dev/tty
    stty echo
    [ -t 1 ] || echo "$PASSWORD"
}
_cmd_pw_check () {
    _ask_pw
    status=0
    decrypted_tmpfile="$(_mktemp)"
    _rm_tmp "$decrypted_tmpfile"
    for file in "$ENC_REPO"/manifest/*; do
        if _decrypt "" <"$file" | _gzip_add_header >"$decrypted_tmpfile"
                gzip -dc <"$decrypted_tmpfile" 2>/dev/null | grep -q "$_tab"; then
            echo "${file##*/}: OK"
        else
            echo "${file##*/}: FAIL"
            status=1
        fi
    done
    return $status
}
_ask_pw () {
    if [ -z "${PASSWORD+1}" ]; then
        if [ "${SECURITY_TOKEN:-}" ]; then
            PASSWORD="$(
                echo 'myba generated password' |
                openssl dgst -engine pkcs11 -keyform engine -sha256 -binary \
                    -sign "pkcs11:object=$SECURITY_TOKEN;type=private" 2>/dev/null |
                base64)"
        else cmd_pw >/dev/null; fi
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
        --cipher-algo AES256 --digest-algo SHA512 --force-aead \
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
    mkdir -p "$ENC_REPO/${_enc_path%/*}"
    is_binary () { git_plain show "HEAD:$_plain_path" | _is_binary_stream; }
    compress_if_text () { if is_binary; then cat; else gzip -nc2 | _gzip_strip_header; fi; }
    git_plain show "HEAD:$_plain_path" |
        compress_if_text |
        _encrypt "$_plain_path" >"$ENC_REPO/$_enc_path"
}
_bind_tty_fd7 () { sh -c ':>/dev/tty' 2>/dev/null && exec 7</dev/tty || exec 7</dev/null; }  # Fd 7 used in _decrypt_file
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
    decrypted_tmpfile_plain="$(_mktemp)"
    _rm_tmp "$decrypted_tmpfile"
    _rm_tmp "$decrypted_tmpfile_plain"
    _decrypt "$_plain_path" <"$ENC_REPO/$_enc_path" >"$decrypted_tmpfile"
    abs_path="$WORK_TREE/$_plain_path"
    mkdir -p "${abs_path%/*}"
    if _gzip_add_header <"$decrypted_tmpfile" | gzip -dc >"$decrypted_tmpfile_plain" 2>/dev/null; then
        cat "$decrypted_tmpfile_plain"
    else
        cat "$decrypted_tmpfile"
    fi >"$abs_path"
}
_decrypt_manifests () {
    status=0
    for file in "$ENC_REPO"/manifest/*; do
        fname="${file##*/}"
        _decrypt "" <"$file" | _gzip_add_header | gzip -dc >"$PLAIN_REPO/manifest/$fname"
        if _is_binary_stream <"$PLAIN_REPO/manifest/$fname"; then
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
    git -C "$PLAIN_REPO" init --bare "$@"
    git -C "$ENC_REPO"   init "$@"
    mkdir -p "$PLAIN_REPO/manifest" \
            "$ENC_REPO/manifest"
    # Don't pollute du
    rm -f "$PLAIN_REPO"/hooks/*.sample \
        "$ENC_REPO"/.git/hooks/*.sample

    # Configure
    email="${EMAIL-${USER-user}@$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo 'localhost')}"
    git_plain config user.name "${USER-user}"
    git_plain config user.email "$email"
    git_plain config status.showUntrackedFiles no  # We don't care to see largely untracked $HOME  # XXX: remove this?
    git_plain config diff.renames "copies"  # Detect renames AND copies
    git_plain config diff.renameLimit 100000
    git_plain config checkout.workers 8
    git_plain config checkout.thresholdForParallelism 20
    git_plain config core.excludesfile ""  # Don't look at $XDG_CONFIG_HOME/git/ignore
    git_plain config advice.addIgnoredFile true  # Warn user to use `add -f` on gitignored file
    git_plain config advice.detachedHead false  # Subprocedures do detached-head checkouts
    git_plain config advice.forceDeleteBranch false  # Avoid "error: the branch 'foo' is not fully merged"
    git_plain config init.defaultBranch main
    git_enc config user.name "${USER-user}"
    git_enc config user.email "$email"
    git_enc config fetch.parallel 4
    git_enc config checkout.workers 8
    git_enc config checkout.thresholdForParallelism 20
    # All our files are strictly binary (encrypted)
    git_enc config core.bigFileThreshold 100
    git_enc config diff.renames "copies"
    git_enc config diff.renameLimit 100000
    git_enc config push.autoSetupRemote true
    git_enc config push.default current
    git_enc config push.followTags true
    git_enc config advice.detachedHead false  # Subprocedures do detached-head checkouts
    git_enc config advice.forceDeleteBranch false  # Avoid "error: the branch 'foo' is not fully merged"
    git_enc config init.defaultBranch main
    # Set up default gitignore
    echo "$default_gitignore" >"$PLAIN_REPO/info/exclude"

    echo '* -text -diff' >"$ENC_REPO/.git/info/attributes"
    # Encrypted repo is a sparse-checkout
    true | _git_enc_sparse_checkout_files
}


cmd_clone () {
    mkdir -p "$ENC_REPO"
    git clone --filter=blob:none --sparse -v "$1" "$ENC_REPO"

    cmd_init

    true | _git_enc_sparse_checkout_files

    _ask_pw
    _decrypt_manifests
}

cmd_decrypt () {
    # Convert the encrypted commit messages back to plain repo commits
    if [ "$(_git_plain_nonbare ls-files)" ]; then
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
    _rm_tmp "$temp_dir"

    have_commitable_changes () { WORK_TREE="$temp_dir" git_plain diff --staged --quiet; }
    decrypt_one () { WORK_TREE="$temp_dir" YES_OVERWRITE=1 _decrypt_file "$1" "$2"; }
    git_add_files () { WORK_TREE="$temp_dir" git_plain add -vf "$@"; }  # -f to ignore .gitignore

    _ask_pw
    _decrypt_manifests
    _bind_tty_fd7
    if [ "${1:-}" = "--squash" ]; then
        git_enc sparse-checkout disable
        # Files available as of the current ref  and for which password exists
        available_files="$(git_enc ls-files |
                           grep -RFhf- "$PLAIN_REPO/manifest" |
                           sort -u -k2)"
        echo "$available_files" |
            _parallelize 0 2 decrypt_one
        # shellcheck disable=SC2046
        git_add_files $(echo "$available_files" | cut -f2)
        if ! have_commitable_changes; then
            WORK_TREE="$temp_dir" git_plain commit -m "Restore '$1' at $(date '+%Y-%m-%d %H:%M:%S%z')"
        fi
    else
        cur_branch="$(git_plain branch --show-current)"
        quiet _trap_append "git_enc checkout --force '$cur_branch'" INT HUP TERM EXIT
        git_enc rev-list --reverse HEAD |
            while IFS= _read_vars _enc_commit; do
                # shellcheck disable=SC2154
                git_enc checkout --force "$_enc_commit"
                git_enc show --name-only --pretty=format: "$_enc_commit" |
                    _git_enc_sparse_checkout_files

                # Decrypt and stage files from this commit into temp_dir
                plain_commit="$(git_enc show --name-only --pretty=format: "$_enc_commit" -- "manifest/" |
                                cut -d/ -f2)"
                _parallelize 0 2 decrypt_one <"$PLAIN_REPO/manifest/$plain_commit"
                # shellcheck disable=SC2046
                git_add_files $(cut -f2 "$PLAIN_REPO/manifest/$plain_commit")

                # Commit the changes to the plain repo
                _msg="$(git_enc show -s --format='%B' "$_enc_commit" |
                        base64 -d | _decrypt "" | _gzip_add_header | gzip -dc)"
                _date="$(git_enc show -s --format='%ai' "$_enc_commit")"
                _author="$(git_enc show -s --format='%an <%ae>' "$_enc_commit")"
                if ! have_commitable_changes; then
                    WORK_TREE="$temp_dir" git_plain commit --no-gpg-sign -m "$_msg" --date "$_date" --author "$_author"
                fi
            done
    fi

    true | _git_enc_sparse_checkout_files
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
    _rm_tmp "$temp_dir"
    WORK_TREE="$temp_dir"  # Don't switcheroo "live" config files!

    cur_branch="$(git_plain branch --show-current)"
    quiet _trap_append "git_plain checkout --force '$cur_branch'" INT HUP TERM EXIT
    # Loop through plain commit hashes and checkout & cmd_commit
    git_plain rev-list --reverse HEAD |
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
#                _decrypt "" <"$ENC_REPO/$manifest" | gzip -dc >"$PLAIN_REPO/$manifest_path".tmp
#                # Temporarily switch to new password and reencrypt
#                old_pw=$PASSWORD
#                PASSWORD="$NPW"
#                gzip -nc2 "$PLAIN_REPO/$m".tmp | _encrypt "" >"$ENC_REPO/$m".new
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

    tmpdir="$(_mktemp -d)"
    _rm_tmp "$tmpdir"
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
        while [ ! -f "$tmpdir/out" ] || [ ! -f "$tmpdir/err" ]; do sleep .01; done
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
    backup_dirs="$(_git_plain_nonbare ls-files "*/$mybabackup_dir" |
                   sed -E "s,/.mybabackup([\"']?)\$,\1,")"
    if [ "$backup_dirs" ]; then
        echo "$backup_dirs" |
            git_plain add -v --pathspec-from-file=-
    fi
}


cmd_commit () {
    # Ask for pw first. This way, the user can cancel and nothing happens
    _ask_pw

    _update_added_dirs

    # Commit to plain repo
    git_plain commit --verbose "$@" --message "myba backup $(date '+%Y-%m-%d %H:%M:%S')"

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
    : >"$PLAIN_REPO/$manifest_path"
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
                echo "$_enc_path$_tab$_path" >>"$PLAIN_REPO/$manifest_path"
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
    if ! git_enc rev-parse HEAD 2>/dev/null; then
        _self="$(command -v "$0" 2>/dev/null || echo "$0")"
        cp "$_self" "$ENC_REPO/${_self##*/}"
        git_enc add -vf --sparse "${_self##*/}"
    fi

    # Stage new manifest
    if [ "$(_file_size "$PLAIN_REPO/$manifest_path")" -gt 0 ]; then
        gzip -nc2 "$PLAIN_REPO/$manifest_path" |
            _gzip_strip_header |
            _encrypt "" >"$ENC_REPO/$manifest_path"
        git_enc add -vf --sparse "$manifest_path"
    else
        rm "$PLAIN_REPO/$manifest_path"
    fi

    # Commit to encrypted repo
    git_enc status --short
    git_enc commit -m "$(
        git_plain show --format='%B' --name-status |
            gzip -nc8 | _gzip_strip_header | _encrypt "" | { base64 -w 0 || base64; })"
}


cmd_checkout() {
    if [ $# -eq 0 ]; then warn "Usage: ${0##*/} checkout (COMMIT | FILE...)"; exit 1; fi
    # If a commit hash is provided, checkout that commit in either repo
    if git_plain rev-parse --verify "$1^{commit}" >/dev/null 2>&1; then
        git_plain checkout "$@"
    elif git_enc rev-parse --verify "$1^{commit}" >/dev/null 2>&1; then
        true | _git_enc_sparse_checkout_files
        git_enc checkout "$@"
        _ask_pw
        _decrypt_manifests
    else
        # Otherwise, assume the arguments are paths to files/directories
        working_manifest="$PLAIN_REPO/checkout.$$"
        working_manifest="$(_mktemp)"
        _rm_tmp "$working_manifest"
        printf '%s\n' "$@" |
            sed -E 's|\.|\\.|g;
                    s/\?/./g;
                    s,\*\*,__GLOBSTAR__,g;
                    s,\*,[^/]*?,g;
                    s/__GLOBSTAR__/.*?/g;
                    s/^/\t/g;
                    s,$,($|/),g' |  # glob expr to RE
            grep -REI -f - "$PLAIN_REPO/manifest" |
            sort -u >"$working_manifest"

        [ "$(wc -l <"$working_manifest")" -gt 1 ] ||
            warn "WARNING: No paths match glob expression(s): $*."'Try `myba decrypt && myba git ls-files`?'

        cut -f1 "$working_manifest" |
            _git_enc_sparse_checkout_files

        _ask_pw
        _bind_tty_fd7
        _parallelize 0 2 _checkout_file <"$working_manifest"
    fi
}


_checkout_file () {
    _enc_path="$1"
    _plain_path="$2"
    if [ -f "$ENC_REPO/$_enc_path" ]; then
        _decrypt_file "$_enc_path" "$_plain_path"
    else
        echo "INFO: File '$_plain_path' committed but removed in a later commit"
    fi
}


cmd_switch () {
    branch="${1-}"
    [ "$branch" ] || {
        export PAGER=
        git_plain branch
        [ "$(git_plain branch)" != "$(git_enc branch)" ] &&
            echo 'Encrypted branches:' >&2 &&
            git_enc branch >&2
        return 0
    }
    if git_plain show-ref --verify --quiet "refs/heads/$branch"; then
        # Switch branches and index but without touching anything in work tree!
        cur_branch="$(git_plain branch --show-current)"
        git_plain symbolic-ref -m "myba switch $cur_branch -> $branch" HEAD "refs/heads/$branch"
        git_plain read-tree --reset "$branch"

        true | _git_enc_sparse_checkout_files
        git_enc checkout --force --quiet "$branch"

        _ask_pw
        _decrypt_manifests
    elif git_enc show-ref --verify --quiet "refs/heads/$branch"; then
        true | _git_enc_sparse_checkout_files
        git_enc checkout --force "$branch"

        cmd_decrypt
    else
        # New vault
        git_plain checkout --orphan "$branch" && git_plain reset --quiet
        git_enc checkout --orphan "$branch" --quiet && git_enc reset --quiet
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
    if [ $# -ge 2 ] && [ "$1" = 'add' ]; then
        # Ideally, this would reside in cmd_init, but then
        # `git remote add` complains 'error: remote origin already exists'
        git_enc config "remote.$2.promisor" true
        git_enc config "remote.$2.partialclonefilter" "blob:none"
    fi
}


cmd_push () {
    has_args= ; for arg; do case "$arg" in -*) ;; *) has_args=1; break ;; esac; done
    if [ ! "$has_args" ]; then
        # With no args, push current branch to all remotes
        warn 'INFO: With no args, pushing current branch to all configured remotes!'
        git_enc remote show |
            while _read_vars _origin; do
                # shellcheck disable=SC2154
                git_enc push --verbose "$@" -- "$_origin" HEAD
            done
    else
        git_enc push --verbose "$@"
    fi

    # If have some remotes and all of them are synced ...
    if git_enc remote show | grep -q . &&
            git_enc for-each-ref refs/heads --format='%(refname:short)' |
                while read -r branch; do
                    commit="$(git_enc rev-parse "$branch")"
                    git_enc branch --remotes --list "*/$branch" |
                    while read -r rbranch; do
                        [ "$(git_enc rev-parse "$rbranch")" = "$commit" ]
                    done
                done; then
        # Remove redundant files including just-pushed packs
        true | _git_enc_sparse_checkout_files
    else warn 'WARNING: Some remotes are not synced! Compare `myba git_enc rev-parse HEAD` to `myba git_enc ls-remote --branches .` (mind the dot).'
    fi
}


cmd_gc () {
    # Reduce disk usage by removing encrypted repo's blobs
    true | _git_enc_sparse_checkout_files

    git_plain gc "$@"
    git_enc gc "$@"

    # Rm packs for which promisor nodes exist. Subsequent fetches
    # redownload missing packs.
    for file in "$ENC_REPO/.git/objects/pack"/pack-*.promisor; do
        rm -f "${file%.promisor}.pack" \
            "${file%.promisor}.idx"
    done
}

_git_plain_add_force () {
    # Plumbing command `update-index --add` does not complain or skip nested repo files
    git_plain update-index --add --verbose "$@"
}

cmd_add () {
    for dir in "$@"; do
        if [ -d "$dir" ]; then
            # Mark directories as recursively tracked
            touch "$dir/$mybabackup_dir"
            _git_plain_add_force "$dir/$mybabackup_dir"

            # Once any dirs that are git repos (contain .git dir) have had added
            # files by `update-index --add`, simple `git add` should work for the
            # nested files afterwards
            git_plain add -v "$dir"

            find "$dir" -type d -name '.git' |
                while read d; do
                    warn "WARNING: Skipping .git dir: \"$d\". If you wish to include it in the backup, you have to copy/rename it before adding. This can be done e.g. in a git hook. You can also use the post-commit hook shipped with ${0##*/}."
                    _git_plain_add_force "${d%/*}"/*
                done
        fi
    done

    git_plain add -v "$@"
}


cmd_largest () {
    ref="${1-HEAD}"
    [ $# -eq 0 ] || shift
    if command -v gnumfmt >/dev/null 2>&1; then numfmt () { gnumfmt; }; fi  # On macOS
    git_plain ls-tree --full-tree -r -t --full-name --format='%(objectsize:padded)%x09%(path)' "$ref" |
        sort -r -n |
        grep -v '^ *-' |
        numfmt --to=iec-i --suffix=B
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

toggle_verbose () {
    # xtrace prompt for sh, bash, zsh. Sets $xtrace with previous xtrace state
    PS4="$(
        if [ "${LINENO:-}" ] && [ "${BASH_VERSION:-}" ]; then lineno=':$LINENO ($?)>'; fi
        printf "\033[34;40;1m+%s${lineno:-}\033[0m " "$0"
    )"
    export PS4
    case $- in *x*) xtrace=-x ;; *) xtrace=+x ;; esac
    case "${VERBOSE:-}" in '') ;; *) set -x ;; esac
}
quiet () {
    case $- in *x*) set +x; xtrace_on=1 ;; *) xtrace_on= ;; esac
    "$@"
    if [ "$xtrace_on" ]; then set -x; fi
}


default_gitignore="
# Ignore self and similar
${PLAIN_REPO##*/}
.myba

"'
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
.bzr/
.hg/
.ipynb_checkpoints/
.osc/
.svn/

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
*.dpkg-*
'


# Main:
cmd=
if [ $# -gt 0 ]; then cmd="$1"; shift; fi

toggle_verbose

case "$cmd" in
    init) cmd_init "$@" ;;
    add) cmd_add "$@" ;;
    rm) cmd_rm "$@" ;;
    commit) cmd_commit "$@" ;;
    remote) cmd_remote "$@" ;;
    push) cmd_push "$@" ;;
    pull) cmd_pull "$@" ;;
    clone) cmd_clone "$@" ;;
    decrypt) cmd_decrypt "$@" ;;
    reencrypt) cmd_reencrypt "$@" ;;
    diff) cmd_diff "$@" ;;
    log) cmd_log "$@" ;;
    status) cmd_status "$@" ;;
    ls-files) cmd_lsfiles "$@" ;;
    largest) cmd_largest "$@" ;;
    checkout) cmd_checkout "$@" ;;
    switch) cmd_switch "$@" ;;
    gc) cmd_gc "$@" ;;
    pw) cmd_pw "$@" ;;
    git_enc) git_enc "$@" ;;
    git)
        # Handle buggy ls-files in bare plain repo
        # https://stackoverflow.com/questions/25906192/git-ls-files-in-bare-repository
        if [ "${1:-}" = "ls-files" ]; then
            shift
            _git_plain_nonbare ls-files "$@"
        else
            git_plain "$@"
        fi
        ;;
    *) usage ;;
esac

set $xtrace
