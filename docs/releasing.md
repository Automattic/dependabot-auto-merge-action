# Releasing

All development happens on github.a8c.com: branches, pull requests, reviews and CI. github.com is a public mirror for WooCommerce and other public repos. Its `main` changes only when a release is pushed to it, and its release is a copy of the github.a8c.com release. Pull requests opened on github.com are moved to github.a8c.com.

The commands below assume two remotes: `ghe` for `git@github.a8c.com:Automattic/dependabot-auto-merge-action.git` and `origin` for `git@github.com:Automattic/dependabot-auto-merge-action.git`.

## 1. Tag the release on github.a8c.com

Merge the release's PRs on github.a8c.com, then tag `main` there:

```bash
git switch main && git pull ghe main
git tag -a v1.7.1 -m v1.7.1
git push ghe v1.7.1
```

The tag starts `release.yml`, which builds the PHAR and creates the github.a8c.com release. Wait for it to finish, and edit the release notes there if needed.

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

`release.yml` skips its job on github.com, so this push builds nothing there.

## 4. Copy the release to github.com

Download the github.a8c.com release's notes and assets, then create the same release on github.com:

```bash
DIR=$(mktemp -d)
gh release view v1.7.1 -R github.a8c.com/Automattic/dependabot-auto-merge-action --json name,body > "$DIR/release.json"
gh release download v1.7.1 -R github.a8c.com/Automattic/dependabot-auto-merge-action -D "$DIR"
jq -r .body "$DIR/release.json" > "$DIR/notes.md"
```

Notes generated on github.a8c.com link to its pull requests, which public readers cannot open. Edit `$DIR/notes.md` to point at the matching commits or drop the links, then publish:

```bash
gh release create v1.7.1 -R github.com/Automattic/dependabot-auto-merge-action --verify-tag \
    --title "$(jq -r .name "$DIR/release.json")" --notes-file "$DIR/notes.md" \
    "$DIR"/dependabot-directories.phar "$DIR"/dependabot-directories.phar.sha256
```

## 5. Check both releases

The two hosts now carry the same PHAR. Download it from github.com and check its checksum:

```bash
cd "$(mktemp -d)" && gh release download v1.7.1 -R github.com/Automattic/dependabot-auto-merge-action --pattern 'dependabot-directories.phar*' && shasum -a 256 -c dependabot-directories.phar.sha256
```
