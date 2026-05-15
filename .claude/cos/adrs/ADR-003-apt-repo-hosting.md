# ADR-003: APT Repository Hosting

**Date**: 2026-05-15  
**Status**: Under Discussion  
**Deciders**: Kevin Adams

## Context

The project currently hosts `.deb` packages on Cloudsmith (a paid SaaS apt repo host). GitHub Actions in the packer repo push to Cloudsmith using an API key secret.

The goal is to evaluate whether to stay with Cloudsmith or move to a self-hosted or GitHub-native solution.

## Options Evaluated

### Option A — Continue with Cloudsmith (Status Quo)

Cloudsmith provides signed apt repos with CDN delivery. The existing repo URLs and GPG keys are already documented in the README and used by real users.

- **Pro**: Already working; users have it configured; CDN; signed packages
- **Con**: External service dependency; potential cost; API key management
- **Verdict**: Keep for now — changing the repo URL would break existing users

### Option B — GitHub Releases

Upload `.deb` files as GitHub Release assets. Users can download manually.

- **Pro**: Free; integrated with GitHub; no extra accounts
- **Con**: Not an apt repo — users can't `apt install` it, only manually download and `dpkg -i`. Not suitable as primary distribution.
- **Verdict**: Add as secondary distribution method (easy downloads for people who don't want apt)

### Option C — GitHub Pages as apt Repo

Use GitHub Actions to build a proper apt repo structure (`dists/`, `pool/`, `Packages.gz`, `Release`, `InRelease`) and deploy it to GitHub Pages. Tools like `apt-ftparchive` or `reprepro` can generate this.

- **Pro**: Free; fully integrated with GitHub; GPG signing still possible; users can add `deb [signed-by=...] https://thegrandwazoo.github.io/freenas-proxmox stable main` to their sources
- **Con**: GitHub Pages URL is less memorable than cloudsmith.io; GPG key management is manual; changing from Cloudsmith would break existing installs
- **Verdict**: Good long-term option if Cloudsmith becomes a problem. Can run in parallel.

### Option D — GitHub Packages (Container Registry / npm-style)

GitHub Packages does not support raw apt repositories natively. Not viable.

## Decision

**Decided 2026-05-15**: Transition from Cloudsmith to GitHub Pages (Option C).

Kevin wants to switch. The transition plan:
1. Build the GitHub Pages apt repo in parallel with Cloudsmith (both active)
2. Update README to point users at GitHub Pages URL
3. Keep Cloudsmith running for existing users until next major release
4. Drop Cloudsmith after v3.x ships (when migration period is over)

GitHub Pages apt repo structure:
```
docs/
├── dists/
│   └── stable/
│       ├── Release
│       ├── InRelease  (GPG signed)
│       └── main/binary-all/
│           ├── Packages
│           └── Packages.gz
└── pool/
    └── main/
        └── freenas-proxmox_*.deb
```

CI uses `apt-ftparchive` to generate `Packages.gz` and `gpg --clearsign` for `InRelease`.
The repo GPG key will live as a GitHub Actions secret.
