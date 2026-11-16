# bclone-image

Our own build of [bclone](https://github.com/BenjiThatFoxGuy/bclone) - a fork of rclone that
carries backends upstream does not ship (teldrive, telegram, alist, alldebrid, terabox, tmpfs,
e621, gotohp) - as a digest-pinned image on GHCR.

**Why a repository of its own instead of pulling the maintainer's image:** the binary we run has
to be the binary we read, and a new fork release must never reach our servers before a human has
diffed it. So the build lives here, behind a manual trigger, next to the audit it is supposed to
follow.

## Start here

**[AUDIT_RUNBOOK.md](AUDIT_RUNBOOK.md) is the entry point**, not this file. It says what to read
before an image may exist, how to build it, what every target machine must pin, and which
findings were already accepted so they do not get re-litigated. [`Dockerfile`](Dockerfile) holds
the four pins (fork commit, source tarball hash, rclone version, rclone base commit);
[`.github/workflows/build-image.yml`](.github/workflows/build-image.yml) only executes them.

Nothing here runs on its own. There is no `push:` trigger, no schedule, no dependency bot: an
image exists only because someone opened the runbook, worked through it, and pressed run.

## Using it as an agent

- Read `AUDIT_RUNBOOK.md` end to end before changing a pin or running a build. A red build is
  information ("an unreviewed upstream release exists"), not a retryable failure.
- The **digest is the pin**; tags (`latest`, `v1.76.2-a90c73a`) are convenience. Consumers record
  the digest in their wrapper's `IMG=` line and the runbook's digest table.
- Fetch source only by full commit SHA from `BenjiThatFoxGuy/bclone`. "continuation" forks of
  that project are known malware lures.
- Do not add source patches, and do not restate findings the accepted-findings table closed.
- Never commit a real home path, account name or host name. Use `/home/user`,
  `/home/<user>`, `/c/Users/<name>` and role names instead - a force push does not undo it,
  because superseded commits stay fetchable by SHA.
- Ask a human before creating a release or pushing: both are externally visible.

## Pull

Public package, anonymous pull, `linux/amd64` and `linux/arm64` in one index:

```
docker pull ghcr.io/<owner>/bclone-image:v1.76.2-a90c73a
docker pull ghcr.io/<owner>/bclone-image@sha256:<digest from the runbook table>
```
