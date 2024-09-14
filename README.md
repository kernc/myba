<img src="icon.svg" width="64"/> Myba — git-based backup utility w/ encryption
=====

**Myba** (pronounced: mỹba) **is an
open-source, secure, distributed, version-controlled, encrypted
file backup software based on `git`**,
for **Linux, MacOS**, and possibly even **Windows/WSL**.
In a world of vice, instability, evergreen browsers, fast-moving markets and near constant _supply chain attacks_,
it's the best kind of backup utility—**a simple shell script** that relies on few, well-tested and _stable_ technologies.
Its only **dependencies are**:

* a running **shell** / standard **POSIX environment** (sh, bash, zsh, dash, ... WSL?),
* **gzip**
* **git** (and Git LFS for files sized >40 MB),
* either **OpenSSL** or **GPG** (~4x slower) for encryption,

all of which everyone should discover most popularly available.

### **Learn more** about the project on [**`myba` backup project website**](https://kernc.github.io/myba/).

See [_smoke-test.sh_](https://github.com/kernc/myba/blob/master/smoke-test.sh) for a covering example / test case!
