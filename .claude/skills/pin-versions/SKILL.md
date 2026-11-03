---
name: pin-versions
description: Look up and pin the current version of a GitHub Action, CLI tool, pre-commit hook, container base image or Terraform provider for the ship-it-safely lab (NFR-3), never guessing a version, SHA, digest or checksum. Load before adding or bumping any of them.
---

# Pin versions (NFR-3)

Never write a version, SHA, digest or checksum from memory. Look it up, then record where it came from in the
commit body. Bump each dependency in its own commit (`ci(deps)`, `chore(repo)` or `build(docker)`) and run
`make check`.

## GitHub Actions: full commit SHA plus a version comment

```bash
gh api repos/<owner>/<repo>/releases/latest --jq .tag_name
gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object.type + " " + .object.sha'
```

If the type is `tag` (annotated), dereference it to the commit:

```bash
gh api repos/<owner>/<repo>/git/tags/<sha> --jq .object.sha
```

Write `uses: <owner>/<repo>@<40-hex commit sha> # <tag>`. Use the same SHA in every workflow; grep for the old
one so no copy is left behind. Skip a release published in the last few days unless it fixes a security issue.
Dependabot keeps them current after that.

## CLI tools: `mise.toml` and `scripts/ci/tools.sha256`

1. Find the latest release on the tool's official release page or GitHub releases.
2. Set the exact version in `mise.toml`.
3. If CI installs it (`scripts/ci/install-tools.sh`), take the SHA-256 for the `linux_amd64` asset from the
   **published** checksums file of that release (for example `*_SHA256SUMS` or `checksums.txt`). Download
   the asset and confirm `shasum -a 256` matches before writing the line. A checksum computed only from your
   own download proves nothing.
4. Run `scripts/selftest/tooling.sh` through `make check`.

## pre-commit hooks

`pre-commit autoupdate --freeze --repo <url>`, which writes `rev: <sha> # frozen: <tag>`. Keep the version in
`mise.toml` in step when the same tool is pinned there.

## Container base images: by index digest

```bash
docker buildx imagetools inspect <image>:<tag> --format '{{json .Manifest.Digest}}'
```

Pin the **index** digest (multi-arch list), not one platform's manifest, in one literal `FROM` line, so Dependabot
can bump it. Python stays on the minor version that ADR 0007 fixes (only digest and patch updates).

## Terraform providers and Terraform itself

- `required_version` and provider constraints in `versions.tf`; bump the `terraform` version in `mise.toml` and
  `scripts/ci/tools.sha256` together.
- Refresh the lock file for both platforms in every root that changed:

```bash
terraform -chdir=<root> providers lock -platform=linux_amd64 -platform=darwin_arm64
```

- Per-env roots are bumped **dev first**: merge and apply dev, then the prod root (ADR 0008 P1). The parity guard
  allows `versions.tf` and the lock file to differ between envs for that window.
