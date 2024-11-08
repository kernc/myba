<img src="icon.svg" width="64" alt/>  Myba — git-based backup utility with encryption
=====

[![Build status](https://img.shields.io/github/actions/workflow/status/kernc/myba/ci.yml?branch=master&style=for-the-badge)](https://github.com/kernc/myba/actions)
[![Language: shell / Bash](https://img.shields.io/badge/lang-Shell-skyblue?style=for-the-badge)](https://github.com/kernc/myba)
[![Source lines of code](https://img.shields.io/endpoint?url=https://ghloc.vercel.app/api/kernc/myba/badge?filter=myba.sh$&style=for-the-badge&color=skyblue&label=SLOC)](https://github.com/kernc/myba)
[![Script size](https://img.shields.io/github/size/kernc/myba/myba.sh?style=for-the-badge&color=skyblue)](https://github.com/kernc/myba)
[![Issues](https://img.shields.io/github/issues/kernc/myba?style=for-the-badge)](https://github.com/kernc/myba/issues)
[![Sponsors](https://img.shields.io/github/sponsors/kernc?color=pink&style=for-the-badge)](https://github.com/sponsors/kernc)

[TOC]

**_Myba_** (pronounced: [_mỹba_](https://www.google.com/search?q=myba)) **is an
open-source, secure, distributed, version-controlled, encrypted
file backup software based on `git`**,
for **Linux, MacOS, BSDs**, and possibly even **Windows/WSL**.
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
respectively, but **git filters can't encrypt the tracked file paths / filenames**,
whereas one might have a want for that, otherwise almost what's the point? 😶

Features
--------
* **Version-controlled (git-based) backup** of plaintext documents as well as large binary files.
* Automatic **text compression** for reduced space use.
* Currently using industry-standard quantum-safe **_strong_ AES256 encryption** of files and paths,
* **Familiar git workflow**: add (stage), commit, push, clone, pull, checkout ...
* **Selective (sparse) checkout** of backup files for restoration, efficient size-on-disk overhead.
* **Sync to multiple clouds** for nearly free by (ab)using popular git hosts.
* **Or sync anywhere simply** by cloning or checking-out a directory ...


How it works
------------
Myba relies on a two-repo solution. On any _client_, **two repositories** are created.
**One plaintext** [`--bare`](https://git-scm.com/book/en/v2/Git-on-the-Server-Getting-Git-on-a-Server) repo,
such as in [this guide](https://www.atlassian.com/git/tutorials/dotfiles),
with `$WORK_TREE` set to the root of your volume of interest,
such as `/` or `$HOME` (default).
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

<script async src="https://ssl.gstatic.com/trends_nrtr/3826_RC01/embed_loader.js"></script>
<div id="trends"></div>
<script>addEventListener("load", () => window.trends.embed.renderExploreWidgetTo(document.getElementById("trends"), "TIMESERIES", {"comparisonItem":[{"keyword":"/m/02mhh1","geo":"","time":"all"},{"keyword":"/m/05vqwg","geo":"","time":"all"},{"keyword":"/m/0ryppmg","geo":"","time":"all"},{"keyword":"myba","geo":"","time":"all"}],"category":0,"property":""}, {"exploreQuery":"date=all&q=%2Fm%2F02mhh1,%2Fm%2F05vqwg,%2Fm%2F0ryppmg,myba#TIMESERIES","guestPath":"https://trends.google.com:443/trends/embed/"}));</script>


### Use-cases

* **Zero-knowledge cloud sync and storage**
  * Replace or supplement existing **poor, complex, expensive, proprietary solutions**
    (like [Veeam](https://www.veeam.com/products/free/backup-recovery.html),
    [Time Machine](https://support.apple.com/en-us/104984),
    [Google One](https://one.google.com/about/plans) Photos & Drive,
    [iCloud](https://www.icloud.com))
    or software programs with **complex, unfamiliar CLI APIs or wide attack surfaces**
    ([Bacula](https://en.wikipedia.org/wiki/Bacula),
    [Borg Backup](https://borgbackup.readthedocs.io/en/stable/usage.html),
    [restic](https://restic.net),
    [git-crypt](https://www.agwa.name/projects/git-crypt/)) ...
* Cloud-based serverless virii
* **Protocol- and PaaS-agnostic** design
  ([AWS](https://aws.amazon.com/free/?all-free-tier.sort-by=item.additionalFields.SortRank&all-free-tier.sort-order=asc&awsf.Free%20Tier%20Types=tier%23always-free&awsf.Free%20Tier%20Categories=categories%23storage)
  to [Backblaze B2](https://www.backblaze.com/cloud-storage/pricing),
  [GitLab](https://about.gitlab.com/pricing/) ...).
  Simply add remote origins or sync (e.g.
  [rsync](https://en.wikipedia.org/wiki/Rsync),
  [rclone](https://rclone.org)) a git folder.


Installation
------------
To install everything on a Debian/Ubuntu-based system, run:
```sh
# Install dependencies
sudo apt install  gzip git git-lfs openssl gpg

# Download and put somewhere on PATH
curl -vL 'https://bit.ly/myba-backup' > ~/.local/bin/myba
chmod +x ~/.local/bin/myba
export PATH="$HOME/.local/bin:$PATH"

myba help
```
Note, only one of `openssl` _or_ `gpg` is needed, not both!

It should be similar, if not nearly equivalent, to install on other platforms.
Hopefully you will find most dependencies already satisfied.

Please report back if you find / manage to get this working under everything but the above configuration and especially Windows/WSL!


Usage
-----
You run the script with arguments according to the usage printout below.
Myba heavily relies on `git` and thus **its command-line usage largely follows that of git convention**.
Most subcommands pass obtained arguments and options (`"$@"`) straight to matching `git` subcommands!
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
  decrypt [--squash]    Reconstruct plain repo commits from encrypted commits
  diff [OPTS]           Compare changes between plain repo revisions
  log [OPTS]            Show commit log of the plain repo
  checkout PATH...      Sparse-checkout and decrypt files into $WORK_TREE
  checkout COMMIT       Switch files to a commit of plain or encrypted repo
  gc                    Garbage collect, remove synced encrypted packs
  git CMD [OPTS]        Inspect/execute raw git commands inside plain repo
  git_enc CMD [OPTS]    Inspect/execute raw git commands inside encrypted repo

Env vars: WORK_TREE, PLAIN_REPO, PASSWORD, USE_GPG, VERBOSE, YES_OVERWRITE, ...
```


### Environment variables

The script also acknowledges a few **environment variables** which you can _set_
(or export) to steer program behavior:

* `WORK_TREE=` The root of the volume that contains important documents (such as dotfiles)
  to back up or restore to. If unspecified, `$HOME`.
* `PLAIN_REPO=` The _internal_ directory where myba actually stores both its repositories.
  Defaults to `$WORK_TREE/.myba` but can be overriden to somewhere out-of-tree ...
* `PASSWORD=` The password to use for encryption instead of asking / reading from stdin.
* `USE_GPG=` Myba uses `openssl enc` by default, but if you prefer to use GPG even for
  symmetric encryption, set `USE_GPG=1`.
* `N_JOBS=` The number of parallel encryption/decryption processes at commit/checkout time.
  By default: 8.
* `KDF_ITERS=` A sufficient number of iterations is used for the encryption key derivation
  function. To specify your own value and avoid rainbow table attacks on myba itself,
  you can customize this value. If you don't know, just leave it.
* `YES_OVERWRITE=` If set, overwrite existing when restoring/checking out files that already
  exist in $WORK_TREE. The default is to ask instead.
* `VERBOSE=` More verbose output about what the program is doing.


### Example use

```sh
# Set volume root to user's $HOME and export for all further commands
export WORK_TREE="$HOME"

myba init
myba add Documents Photos Etc .dotfile
PASSWORD='secret'  myba commit -m "my precious"
myba remote add origin "/media/usb/backup"
myba remote add github "git@github.com:user/my-backup.git"
VERBOSE=1 myba push  # Push to all configured remotes & free up disk space

# Somewhere else, much, much later, avoiding catastrophe ...

export WORK_TREE="$HOME"
PASSWORD='secret'  myba clone "..."  # Clone one of the known remotes
myba checkout ".dotfile" # Restore backed up files in a space-efficient manner
```
See [_smoke-test.sh_](https://github.com/kernc/myba/blob/master/smoke-test.sh) file for a more full example & test case!


Contributing
------------
The project is written for a POSIX shell and is [hosted on GitHub](https://github.com/kernc/myba/).

The script is considered _mostly_ feature-complete, but there remain
bugs and design flaws to be discovered and ironed out, as well as any
[TODOs and FIXMEs](https://github.com/search?q=repo%3Akernc%2Fmyba+%28todo+OR+fixme+OR+xxx%29&type=code)
marked in the source.
**All source code lines are open to discussion.**
Especially appreciated are targets for simplification
and value-added testing.


FAQ
---
<div markdown="1" property="about" typeof="FAQPage">

<details markdown="1" property="mainEntity" typeof="Question">
<summary property="name">Is git a good tool for backups?</summary>
<div markdown="1" property="acceptedAnswer" typeof="Answer"><div markdown="1" property="text">

The inherently core features of git/myba allow you to:

* track a list of important files,
* track all changes made, with authorship info and datums, to any of the tracked files,
* securely store copies of files at each commited snapshot,
* efficiently compress non-binary files,
* [apply custom script filters](https://git-scm.com/book/ms/v2/Customizing-Git-Git-Attributes) to files
  based on file extension / glob string match,
* execute [custom script hooks](https://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks)
  at various stages of program lifecycle.

**[Git](https://en.wikipedia.org/wiki/Git)
is a stable and reliable tool used by millions
of people and organizations worldwide**,
with long and rigorous release / support cycles.

</div></div></details>
<details markdown="1" property="mainEntity" typeof="Question">
<summary property="name">Can git track file owner and permissions etc.?</summary>
<div markdown="1" property="acceptedAnswer" typeof="Answer"><div markdown="1" property="text">

Git doesn't on its own track file owner and permission changes (other than the executable bit).
Files commited by any user are **restorable by any user with the right password**.
In order to restore files with specific file permission bits set, **defer to
[umask](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/umask.html)**,
e.g.:

```sh
umask 0077  # Restore files with `u=rwx,g=,o=`
WORK_TREE=~ myba checkout .ssh
```

If you need to restore file owners, file access times and similar metadata,
simply **write a small shell wrapper** that takes care of it.
**You're encouraged to contrib** anything short to the respect
you find widely-applicable and useful.

</div></div></details>
<details markdown="1" property="mainEntity" typeof="Question">
<summary property="name">Can we use git for continually changed databases and binary files?</summary>
<div markdown="1" property="acceptedAnswer" typeof="Answer"><div markdown="1" property="text">

Git saves whole file snapshots and doesn't do any in-file or within-file
or across-file deduplication, so it's not well-suited to automatic continual backing up
of databases (i.e. large binaries) that change often.

However, while git repositories bloat when commiting such **large binary and media files**,
**_myba_ only ever uses sparse-checkout**, keeping overhead disk space use to a minimum.

</div></div></details>
<details markdown="1" property="mainEntity" typeof="Question">
<summary property="name">How to influence what files / filetypes to (ignore from) backup?</summary>
<div markdown="1" property="acceptedAnswer" typeof="Answer"><div markdown="1" property="text">

You stage files and directories for backup with version control as normally, with `myba add`.
You can edit `$PLAIN_REPO/info/exclude`, which is **prepopulated with
[default common ignore patterns](https://github.com/search?q=repo%3Akernc%2Fmyba+%22default_gitignore%3D%22&type=code)**.
Additionally by inheritance, **myba
[honors _.gitignore_ files](https://git-scm.com/docs/gitignore)**
for any directories that contain them.
You can tweak various other git settings (like
[config](https://git-scm.com/docs/git-config),
[filters](https://git-scm.com/book/ms/v2/Customizing-Git-Git-Attributes#filters_a),
[hooks](https://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks))
by modifying respective files in `$PLAIN_REPO` and (encrypted repo) `$PLAIN_REPO/_encrypted/.git`.

</div></div></details>
<details markdown="1" property="mainEntity" typeof="Question">
<summary property="name">Encryption failed. How do I investigate / recover?</summary>
<div markdown="1" property="acceptedAnswer" typeof="Answer"><div markdown="1" property="text">

Myba constructs encrypted repo commits _after_ successful plain repo commits.

Use `myba git` and `myba git_enc` subcommands to discover what state you're in (e.g. `myba git status`).
Then use something like `myba git reset HEAD^ ; myba git_enc reset HEAD` to reach an acceptable state.

**If it looks like a bug, please report it.**
Otherwise git will let you know what the problem is.

Myba only **deletes redundant encrypted blobs after successfully pushing to _all_ configured remotes**,
and **never deletes or overwrites existing files in work tree** unless forced!

</div></div></details>
</div>
