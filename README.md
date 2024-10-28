<img src="icon.svg" width="64" alt/> Myba — git-based backup utility w/ encryption
=====

[![Build status](https://img.shields.io/github/actions/workflow/status/kernc/myba/ci.yml?branch=master&style=for-the-badge)](https://github.com/kernc/myba/actions)
[![Language: shell / Bash](https://img.shields.io/badge/lang-Shell-skyblue?style=for-the-badge)](https://github.com/kernc/myba)
[![Source lines of code](https://img.shields.io/endpoint?url=https://ghloc.vercel.app/api/kernc/myba/badge?filter=myba.sh$&style=for-the-badge&color=skyblue&label=SLOC)](https://github.com/kernc/myba)
[![Script size](https://img.shields.io/github/size/kernc/myba/myba.sh?style=for-the-badge&color=skyblue)](https://github.com/kernc/myba)
[![Issues](https://img.shields.io/github/issues/kernc/myba?style=for-the-badge)](https://github.com/kernc/myba/issues)
[![Sponsors](https://img.shields.io/github/sponsors/kernc?color=pink&style=for-the-badge)](https://github.com/sponsors/kernc)

**_Myba_** (pronounced: _mỹba_) **is an
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

### **Learn more** about the project on [**`myba` backup project website**](https://kernc.github.io/myba/).

See [_smoke-test.sh_](https://github.com/kernc/myba/blob/master/smoke-test.sh) for a covering example / test case!


Contributing
------------
The script is considered _mostly_ feature-complete, but there remain
bugs and design flaws to be discovered and ironed out, as well as any
[TODOs and FIXMEs](https://github.com/search?q=repo%3Akernc%2Fmyba+%28todo+OR+fixme+OR+xxx%29&type=code)
marked in the source.
**All source code lines are open to discussion.**
Especially appreciated are targets for simplification
and value-added testing.
