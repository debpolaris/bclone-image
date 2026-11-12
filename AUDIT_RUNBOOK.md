# bclone image: audit gate and build recipe

## Why this exists
We run our own Docker image of bclone (https://github.com/BenjiThatFoxGuy/bclone), a fork of
rclone carrying backends upstream does not ship: teldrive, telegram, alist, alldebrid, terabox,
tmpfs, e621, gotohp. We build from source rather than pulling the maintainer's image because
(1) the binary we run must be the binary we read, and (2) a new fork release must never reach
our servers before a human has diffed it. Work through this document when the fork releases,
when the pinned digest is more than 90 days old, or when a backend misbehaves.

## Non-negotiables
- Audit first, build second. The workflow is `workflow_dispatch` only: nothing builds itself.
- Fetch source only by full commit SHA from `BenjiThatFoxGuy/bclone`. "continuation" forks of
  this project are known malware lures - the maintainer warns about them in the README.
- Pins live in the Dockerfile ARGs, which are the single source of truth. Undocumented is undone.
- No source patches. The 2026-11-12 patch set was dropped from scope because the telegram
  remote stays unconfigured. If that changes, re-audit before enabling.

## Audit procedure
1. Our running image: `docker image inspect $IMG -f '{{json .Config.Labels}}'` gives the fork
   revision and the upstream rclone base commit it was cut from.
2. Upstream: `GET /repos/BenjiThatFoxGuy/bclone/commits?per_page=1` plus `/releases/latest`.
   If the SHA already equals the Dockerfile ARG, stop - there is nothing to review.
3. Download three trees. This is the only reliable way to separate fork edits from upstream drift:
   bclone at `$REV`, rclone at the tag named in bclone's `VERSION`, and rclone at the base commit
   recorded in the ARG `RCLONE_BASE`.
4. `diff -qr <base> <rclone-tag>` is upstream drift: ignore it, those are rclone's own commits.
   `diff -qr <base> <bclone>` is the fork delta: review only this one.
5. Read every fork-delta path outside `backend/<new remote>`, in this order:
   credentials and network first (`lib/oauthutil`, `fs/config*`, `fs/fshttp`, `fs/rc/**`,
   `go.mod` - a `replace` directive is the worst smell you can find there), then anything that
   changes an existing backend's behaviour, then anything writing outside its own config section.
6. Inside each new backend, grep for outbound host literals, `os/exec`, `net.Dial` and reads of
   other remotes' config sections. Compare hosts against the provider's own domains.
7. Per-file verdicts go in a scratch table. Close with SAFE, SAFE-WITH-CONDITIONS, or NOT SAFE.
   NOT SAFE means: do not build. Write the finding to the maintainer instead.

## Accepted on 2026-11-12 - do not re-litigate, just confirm the delta has not grown
| Finding | Disposition |
|---|---|
| No `isHTTPSDowngrade` guard, no unauthenticated rc body cap | upstream lag after `RCLONE_BASE`, not a removal |
| GCS `us-east5` option gone; `self-hosted` rewritten as `ubuntu-latest` | cosmetic regressions |
| `docs/content/privacy.md` trimmed | documentation only |
| `multi_thread_resume` drops `O_TRUNC` on local writes | default off, leave it off |
| `_jobid` custom rc job IDs, altered `[fs]/remote` regex | fork features, no credential path |
| telegram: session equals full account, Tier 4/untested, 5000-message scan cap, 0644 cache | remote not configured |
| `bin/zip.3.0.nupkg`, `.github/testdata/gotohptest.png` unreferenced | dead files, never built in |

## Build
`docker buildx build --platform linux/amd64,linux/arm64`: CGO is off, so no emulator is needed.
The workflow prints `docker pull <image>@<digest>` in its summary; append that row here after
running the smoke test below.

Smoke test on the machine that will run it: `rclone version` must report `go/linking: static`,
`help backends` must still list the fork additions, and `mount` must come up and serve a read
and a write. The digest is the pin; the tag is convenience.

## Digest log

| digest | fork revision | verdict | date |
|---|---|---|---|
| `sha256:545c7d91afcf1f27e97e29ca198ea70b34e2e6533cc66af04ac4093520021c2c` | `a90c73aab01c06769064f83a0954e1ca18d170b7` | pulled anonymously, 80 backends incl. all 14 fork additions + `crypt` + `filen`, alpine 3.22.8, FUSE mount read+write verified on the free-tier e2-micro / COS target | 2026-11-12 |

Provenance: the workflow sets `provenance: true` and its log shows `exporting attestation
manifest` for both platforms, but the trust anchor here is the build itself - source fetched by
pinned SHA and verified against `BCLONE_TGZ_SHA256`. `gh attestation verify oci://<image>@<digest>`
needs gh >= 2.49 (2.46 has no `attestation` command), so treat it as optional extra assurance.


## Deployment notes for Container-Optimized OS targets
- `/home`, `/var`, `/tmp` are noexec: never bind-mount a binary and run it; run the image.
- SSH sessions on these VMs inherit a Windows `$HOME` (`/c/Users/<name>`), which does not exist
  there. Never build a path from `~` or `$HOME`: use the absolute `/home/<user>/.config/rclone`
  and pass `-e HOME=/config -e XDG_CONFIG_HOME=/config` into the container, or rclone will read
  an empty config and report no remotes while the file sits on disk.
- Always pass `--user $(id -u):$(id -g)`, or the container writes root-owned config that the
  SSH user can no longer read.
- Wrappers call `docker run -i`; any script calling a wrapper must add `</dev/null`, otherwise
  docker swallows the remainder of the script.
- Mount only the config file whose remote the container is meant to serve.
- 1 GiB RAM: `--transfers 1 --buffer-size 8M`, teldrive `chunk_size=64M`, Filen
  `upload_concurrency=4`. These are system options, so they belong in the wrapper, not in a
  remote section of rclone.conf.
- `rclone mount` needs `--device /dev/fuse --cap-add SYS_ADMIN`, plus
  `--security-opt apparmor=unconfined` on COS: its `docker-default` AppArmor profile makes
  `fusermount3` fail with `mount failed: Permission denied` even with SYS_ADMIN, and
  `seccomp=unconfined` or extra capabilities do not help. `--privileged` also works but is
  wider than needed. Verified 2026-11-12 by mounting and reading and writing through the mount.

