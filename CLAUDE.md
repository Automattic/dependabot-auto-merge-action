# Working in this repo

- **Develop on github.a8c.com.** Push branches to the `ghe` remote and open pull requests there, with `GH_HOST=github.a8c.com gh pr create` or `-R github.a8c.com/Automattic/dependabot-auto-merge-action`. Never open a pull request on github.com.
- **github.com changes only at release time.** Its `main` and tags are pushed by hand when a release is cut, and its release is a copy of the github.a8c.com one. Follow [docs/releasing.md](docs/releasing.md).
