<img src="icon.svg" width="64" alt/>  Myba — git-based backup utility with encryption
=====

[TOC]

[![Build Status](https://img.shields.io/github/actions/workflow/status/kernc/myba/ci.yml?branch=master&style=for-the-badge)](https://github.com/kernc/myba/actions)
[![Issues](https://img.shields.io/github/issues/kernc/myba?style=for-the-badge)](#)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/kernc?color=pink&style=for-the-badge)](https://github.com/sponsors/kernc)

**Myba** (pronounced: mỹba) **is an
open-source, secure, distributed, version-controlled, encrypted
file backup software based on `git`**,
for **Linux, MacOS**, and possibly even **Windows/WSL**.
In a world of vice, instability, evergreen browsers, fast-moving markets and near constant _supply chain attacks_,
it's the best kind of backup utility—**a timeless shell script** that relies on few, well-tested and _stable_ technologies.
Its only **dependencies are**:

* a running **shell** / standard **POSIX environment** (sh, bash, zsh, dash, ... WSL?),
* **gzip**
* **git** (and Git LFS for files sized >40 MB),
* either **OpenSSL** or **GPG** (~4x slower) for encryption,

all of which everyone should discover most popularly available.

**Git does a great job of securely storing and tracking changes and backing up important documents,**
it is popular and widely-deployed,
[feature-rich](https://git-man-page-generator.lokaltog.net/),
but it doesn't on its own support encryption, which might be important if the backed-up data 
is going to be shared with untrusted (and untrustworthy) third parties
and various intermediary data "processors".
One _could_ most simply set up an encryption-decryption process
consisting of [**`clean` and `smudge` git filters** issued pre commits and post checkouts](https://git-scm.com/book/ms/v2/Customizing-Git-Git-Attributes#filters_a),
respectively, but the **filters can't encrypt the tracked file paths / filenames**,
whereas one might have a want for that, otherwise almost what's the point? 😶

Features
--------
* **Version-controlled (git-based) backup** of plaintext documents as well as large binary files.
* Automatic **text compression** for reduced space use.
* Currently using **_strong_ AES256 encryption** of files and paths, so far quantum-safe.
* Familiar git workflow: add, stage, commit, push, clone, pull, checkout.
* **Selective checkout** of backup files, efficient size-on-disk overhead.
* **Sync to multiple clouds** for nearly free by (ab)using popular git hosts.
* **Or sync anywhere simply** by cloning or checking-out a directory ...


How it works
------------
Myba relies on a two-repo solution. On any _client_, **two repositories** are created.
**One plaintext** [`--bare`](https://git-scm.com/book/en/v2/Git-on-the-Server-Getting-Git-on-a-Server) repo,
such as in [this guide](https://www.atlassian.com/git/tutorials/dotfiles),
with worktree set to the root of your volume of interest, such as `/` or `$HOME`.
And **one encrypted** repo that holds encrypted file counterparts.

When you `myba commit` some files into the plain repo,
a commit to the encrypted repo is made in the background.

When you `myba checkout`, a file is checked out from the
encrypted repo and restored back onto your volume.

When you `myba push` your commit history successfully (exit code 0)
to all configured remotes
(any `git remote`, such as a special folder or a cloud host),
the **local encrypted blobs are deleted to save disk space**,
relying on recently-stabilized
[`git sparse-checkout`](https://git-scm.com/docs/git-sparse-checkout) and 
[partial `git clone --filter=blob:none`](https://git-scm.com/docs/partial-clone) features,
all in all at a minimized and efficient space cost best-suited to backing up
text and configuration files, source code files, documents and pictures,
including all kinds or large binary files
(as much as you can afford to sync to your cloud storage),
**all under the assumptions that text files compress well** and
that **large binaries don't change too often**.

**Myba** is **Git + Shell**, preconfigured and wrapped as thinly as needed to provide
fully **encrypted backups** that are really **easily replicated and synced to the cloud**.

<script src="https://ssl.gstatic.com/trends_nrtr/3826_RC01/embed_loader.js"></script>
<script>window.trends.embed.renderExploreWidget("TIMESERIES", {"comparisonItem":[{"keyword":"/m/02mhh1","geo":"","time":"2004-01-01 2024-10-13"},{"keyword":"/m/05vqwg","geo":"","time":"2004-01-01 2024-10-13"},{"keyword":"/m/0ryppmg","geo":"","time":"2004-01-01 2024-10-13"}],"category":0,"property":""}, {"exploreQuery":"q=%2Fm%2F02mhh1,%2Fm%2F05vqwg,%2Fm%2F0ryppmg&date=all#TIMESERIES","guestPath":"https://trends.google.com:443/trends/embed/"})</script>


### Use-cases

* **Zero-knowledge cloud sync and storage**
* Replace or supplement existing **poor complex and proprietary solutions** (like Veeam, Time Machine, Google Photos & Drive, iCloud)
  or software programs with **complex and unfamiliar CLI APIs or wide attack surfaces** (Bacula, Borg Backup, restic) ...
* Cloud-based serverless virii
* **Protocol- and PaaS-agnostic** design (AWS to Backblaze B2, GitLab to Gitea). Simply sync (even rsync) a git folder.


Installation
------------
To install everything on a Debian/Ubuntu-based system, run:
```sh
# Install dependencies
sudo apt install  gzip git git-lfs openssl gpg

# Download and make available somewhere in path
curl -L https://bit.ly/myba-backup > ~/.local/bin/myba
export PATH="$HOME/.local/bin:$PATH"

myba help
```
Note, only one of `openssl` _or_ `gpg` is needed, not both!

It should be similar, if not nearly equivalent, to install on other platforms.
Hopefully you will find most dependencies already satisfied.

Please report back if you find / manage to get this working under anything but the above configuration and especially Windows/WSL!


Usage
-----
You run the script with arguments according to the usage printout below.
Myba heavily relies on `git` and thus **its command-line usage largely follows that of git convention**.
Most subcommands pass obtained arguments and options (`"@"`) straight to matching `git` subcommands! 
```text
Usage: myba <subcommand> [options]
Subcommands:
  init                  Initialize repos in $WORK_TREE (default: $HOME)
  add [OPTS] PATH...    Stage files for backup/version tracking
  rm PATH...            Stage-remove files from future backups/version control
  commit [OPTS]         Commit staged changes of tracked files as a snapshot
  push [REMOTE]         Encrypt and push files to remote repo(s) (default: all)
  pull [REMOTE]         Pull encrypted commits from a promisor remote
  clone REPO_URL        Clone an encrypted repo and init from it
  remote CMD [OPTS]     Manage remotes of the encrypted repo
  restore [--squash]    Reconstruct plain repo commits from encrypted commits
  diff [OPTS]           Compare changes between plain repo revisions
  log [OPTS]            Show commit log of the plain repo
  checkout PATH...      Sparse-checkout and decrypt files into $WORK_TREE
  checkout COMMIT       Switch files to a commit of plain or encrypted repo
  gc                    Garbage collect, remove synced encrypted packs
  git CMD [OPTS]        Inspect/execute raw git commands inside plain repo
  git_enc CMD [OPTS]    Inspect/execute raw git commands inside encrypted repo

Env vars: WORK_TREE, PLAIN_REPO, PASSWORD USE_GPG, VERBOSE, YES_OVERWRITE, ...
```
The script also acknowledges a few **environment variables** which you can _set_ to
steer the program behavior:


### Environment variables

* `WORK_TREE=` The root of the volume that contains important documents to back up (such as dotfiles).
  If unspecified, `$HOME`.
* `PLAIN_REPO=` The _internal_ directory where myba actually stores both its repositories.
  Defaults to `$WORK_TREE/.myba` but can be overriden to somewhere out-of-tree ...
* `PASSWORD=` The password to use for encryption instead of asking / reading from stdin.
* `USE_GPG=` Myba uses `openssl enc` by default, but if you prefer to use GPG for symmetric encryption, set `USE_GPG=1`.
* `KDF_ITERS=` A sufficient number of iterations is used for the encryption key derivation function.
  To specify your own value and avoid rainbow table attacks on myba itself, you can customize this value.
  If you don't know, just leave it.
* `YES_OVERWRITE=` If set, overwrite existing when restoring/checking out files that already exist in $WORK_TREE. 
  The default is to ask instead.
* `VERBOSE=` More verbose output about what the program is doing.


### Example use

```shell
# Set volume root to the user's $HOME and export for everyone
export WORK_TREE="$HOME"
myba init
myba add Documents Photos Etc .dotfile
PASSWORD=secret  myba commit -m "my precious"
myba remote add origin "/media/usb/backup"
myba remote add github "git@github.com:user/my-backup.git"
myba push  # Push to all configured remotes & free disk space

# Somewhere else, much, much later, avoiding catastrophe ...

export WORK_TREE="$HOME"
PASSWORD=secret  myba clone "..."  # Clone one of the known remotes
myba checkout ".dotfile" # Restore backed up files in a space-efficient manner
```
See [_smoke-test.sh_](https://github.com/kernc/myba/blob/master/smoke-test.sh) file for a more full example & test case!
