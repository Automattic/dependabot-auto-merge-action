# Releasing

Development happens on github.a8c.com. github.com is a public mirror for WooCommerce and other public repos, and it only changes when a release is pushed to it by hand.

The commands below assume two remotes: `ghe` for `git@github.a8c.com:Automattic/dependabot-auto-merge-action.git` and `origin` for `git@github.com:Automattic/dependabot-auto-merge-action.git`.

## 1. Tag the release on github.a8c.com

Merge the release's PRs on github.a8c.com, then tag `main` there:

```bash
git switch main && git pull ghe main
git tag -a v1.7.1 -m v1.7.1
git push ghe v1.7.1
```

The tag starts `release.yml`, which builds the PHAR and creates the github.a8c.com release.

## 2. Check what github.com will receive

```bash
git fetch origin
git log --oneline origin/main..v1.7.1
```

Every commit listed goes public. github.com's `main` must be an ancestor of the tag, or the push in the next step is refused.

## 3. Push the release to github.com

Push the tagged commit to `main` and the tag in one atomic push, so neither lands without the other:

```bash
git push --atomic origin 'v1.7.1^{commit}:refs/heads/main' refs/tags/v1.7.1
```

The push goes straight to `main`, so the person pushing needs a bypass on github.com's `main-branch-ruleset` that allows direct pushes, not only pull requests. Never force it. A refused push means github.com has commits github.a8c.com lacks, and those need bringing across first.

The tag starts github.com's own `release.yml`, which builds that host's PHAR and release.

## 4. Check both releases

On each host, download the PHAR and check its checksum:

```bash
gh release download v1.7.1 -R Automattic/dependabot-auto-merge-action --pattern 'dependabot-directories.phar*'
shasum -a 256 -c dependabot-directories.phar.sha256
```

Run it once as is for github.com, and once with `GH_HOST=github.a8c.com` for github.a8c.com. Each host builds its own PHAR, so the two checksums can differ.
