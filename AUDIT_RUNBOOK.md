# bclone image: audit gate and build recipe

## Why this exists
We run our own Docker image of bclone (https://github.com/BenjiThatFoxGuy/bclone), a fork of
rclone carrying backends upstream does not ship: teldrive, telegram, alist, alldebrid, terabox,
tmpfs, e621, gotohp. We build from source rather than pulling the maintainer's image because
(1) the binary we run must be the binary we read, and (2) a new fork release must never reach
our servers before a human has diffed it. Work through this document when the fork releases,
when the `date` in the newest digest-log row is more than 90 days old, or when a backend
misbehaves.

## Non-negotiables
- Audit first, build second. The workflow is `workflow_dispatch` only: nothing builds itself.
- Fetch source only by full commit SHA from `BenjiThatFoxGuy/bclone`. "continuation" forks of
  this project are known malware lures - the maintainer warns about them in the README.
- Pins live in the Dockerfile ARGs, which are the single source of truth. Undocumented is undone.
- No source patches. The 2026-11-12 patch set was dropped from scope because the telegram
  remote stays unconfigured. If that changes, re-audit before enabling.
- Nothing that identifies a person's machine enters this repository. Write `/home/user`,
  `/home/<user>`, `/c/Users/<name>` and role names ("the free-tier e2-micro / COS target"),
  never a real home path, account name or host name - in file contents *and* in commit
  messages. A force push does not undo it: superseded commits stay fetchable by SHA.

## Coordinates
- Image: `ghcr.io/<owner>/<repo>` — the path is the repository's GitHub `owner/name`, lowercased,
  which is what the workflow composes and prints; this document deliberately does not spell the
  owner out. The authoritative string is in the workflow run summary, the GitHub Release body and
  each wrapper's `IMG=` line. Public package: no login, no `docker pull` credential.
- Tags: `latest` plus `v<rclone version>-<first 7 of fork SHA>`, e.g. `v1.76.2-a90c73a`. Both are
  convenience; the digest in the table below is the pin. There are no per-architecture tags.
- The pin lives in four Dockerfile ARGs: `BCLONE_REV` (fork commit), `BCLONE_TGZ_SHA256`
  (source tarball hash), `BCLONE_VERSION` (the rclone version the fork's `VERSION` names),
  `RCLONE_BASE` (the rclone commit the fork cut from). `$REV` in the audit steps means
  `BCLONE_REV`; `$IMG` means the image as a `name:tag` or `name@digest` reference.
- Workflow: `.github/workflows/build-image.yml`, run with
  `gh workflow run build-image.yml -f push=true` from a `gh` that is logged in to the account
  owning this repo (the build itself authenticates to GHCR with the run's `GITHUB_TOKEN`, not
  yours). It refuses to build while an unreviewed upstream release exists, so a red build is
  information, not a failure to retry away.
- Split of labour: the Audit procedure needs only `curl`, `tar`, `diff` and `git` on any machine —
  no docker, no buildx. The Digest log checks and the smoke test need docker on the target, and
  listing per-platform digests needs `skopeo` or `docker buildx imagetools`, neither of which is
  guaranteed on a Container-Optimized OS host.
- Release: one per audited build, tagged with the same `v<rclone>-<fork7>` string as the image tag,
  body holding the four pins, the index digest and both per-platform digests. A human publishes it
  after the digest log row exists; the workflow never creates releases, which is why an unreviewed
  build cannot become visible documentation by accident.
- Consumers pin the image in `IMG=` inside each target's wrapper script
  (`/home/<user>/bclone/bc`, `/home/<user>/bclone/td`). After a new build: update that line,
  re-run the smoke test on that target, and append the digest row here. Skipping it leaves the
  target running an image the digest log does not describe.

## Audit procedure
1. Our running image: `docker image inspect $IMG -f '{{json .Config.Labels}}'` gives the fork
   revision and the upstream rclone base commit it was cut from.
2. Upstream, three reads (unauthenticated `curl` is rate-limited to 60 req/h per IP; `jq` is
   optional, `grep -o` works on the same JSON):
   ```
   curl -fsSL https://api.github.com/repos/BenjiThatFoxGuy/bclone/commits?per_page=1   # -> .[0].sha
   curl -fsSL https://api.github.com/repos/BenjiThatFoxGuy/bclone/releases/latest      # -> .tag_name, .body
   curl -fsSL "https://api.github.com/repos/BenjiThatFoxGuy/bclone/compare/$REV...$NEW_SHA"
   ```
   If `.[0].sha` already equals `BCLONE_REV`, stop - there is nothing to review. The `compare`
   URL needs **three** dots (`base...head`); `base..head` returns 404. Its `.commits[].commit.message`
   is the "what changed" list and `.files[].filename` the touched paths, which is how you decide
   whether the delta is a new backend, a credential path, or a README.
   Measured 2026-11-16: fork tip `a90c73ab…` (== the pin) and newest release `v1.76.2` (== the pin),
   so both the audit and the workflow's version gate currently pass with nothing to review.
   The fork ships no signatures, so release notes are a claim until the diff below says otherwise.
3. Download three trees. This is the only reliable way to separate fork edits from upstream drift:
   bclone at `$REV` (`https://codeload.github.com/BenjiThatFoxGuy/bclone/tar.gz/$REV`, whose hash
   must equal `BCLONE_TGZ_SHA256`), rclone at the tag named in bclone's `VERSION`, and rclone at
   the base commit recorded in the ARG `RCLONE_BASE`.
4. `diff -qr <base> <rclone-tag>` is upstream drift: those are rclone's own commits, not the fork's
   doing, so do not review them file by file. But do not swallow them either: grep that list for the
   credential and network paths in step 5, because upstream fixes you do not have are what the
   accepted-findings table below records. `diff -qr <base> <bclone>` is the fork delta: review only
   this one.
5. Read every fork-delta path outside `backend/<new remote>`, in this order:
   credentials and network first (`lib/oauthutil`, `fs/config*`, `fs/fshttp`, `fs/rc/**`,
   `go.mod` - a `replace` directive is the worst smell you can find there), then anything that
   changes an existing backend's behaviour, then anything writing outside its own config section.
6. Inside each new backend, grep for outbound host literals, `os/exec`, `net.Dial` and reads of
   other remotes' config sections. Compare hosts against the provider's own domains.
7. Per-file verdicts go in a scratch table (one row per fork-delta path: verdict + why). Close with
   SAFE, SAFE-WITH-CONDITIONS, or NOT SAFE, and reuse that word in the digest log's `verdict` cell.
   NOT SAFE means: do not build. Write the finding to the maintainer instead.
8. Re-check the accepted-findings table without re-reading it: diff `<base>` against the new bclone
   tree and look for the paths that table names (`fs/fshttp`, `backend/googlecloud`, `multi_thread_resume`
   in `backend/sftp`-adjacent copy paths, `lib/oauthutil`, telegram's cache writer). If none of them
   moved, the delta has not grown and the table still holds. If one moved, that row is open again.
   The two rows closed by *configuration* rather than code need a live check each time: no deployed
   `rclone.conf` may contain a telegram remote (`grep -c 'type = telegram'` across the bound config
   directories), and `multi_thread_resume` must stay unset.

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
`docker buildx build --platform linux/amd64,linux/arm64`: `CGO_ENABLED=0` is set in the Dockerfile,
so the Go toolchain cross-compiles both architectures itself and buildx needs no QEMU/binfmt
emulator for them - both manifests come out of one runner, which is why one index digest is the
whole build.
The workflow prints `docker pull <image>@<digest>` in its summary; append that row here after
running the smoke test below.

**Architectures.** One build publishes one OCI image index, and that index digest is what the
digest log records: pulling it resolves to the matching platform manifest, so the same string is
correct on amd64 and arm64. Measured 2026-11-16 against the pinned index (`latest` and
`v1.76.2-a90c73a` both still resolve to it, built 2026-11-12):

| platform | manifest digest | executed here? |
|---|---|---|
| `linux/amd64` | `sha256:383f1a505d5504fbccd555734531224a70fa36a3f85f9cc9c9607a4052d829a6` | yes - e2-micro / COS, FUSE read+write 2026-11-12 and 2026-11-16 |
| `linux/arm64` | `sha256:b3ede6472938138e19ba841b09911c357115ab095eb48a89eeff4dc78ed432b8` | no - manifest and config inspected only |

Quote these per-platform digests when one architecture is under discussion. There are no
architecture-specific tags. To list them yourself, on a machine that has `skopeo` (a Proxmox host
does; a COS VM does not) and no credentials for a public package:

```
skopeo inspect --raw docker://$IMG | sha256sum        # the index digest itself
skopeo inspect --raw docker://$IMG                    # entries: 2 platforms + 2 attestation
skopeo inspect --config docker://$IMG@$PLATFORM_DIGEST  # architecture, env, pin labels
```

The raw index has four entries: two platforms and two `unknown/unknown` attestations, which are
expected, not extra payloads. On a Docker host instead, `docker buildx imagetools inspect $IMG`
prints the same list.

An arm64 consumer (an Oracle A1 free-tier shape, for instance) has never run this binary. Nothing
available here can execute arm64 - no arm64 host and no `qemu-aarch64` on the machines we control -
so `architecture: arm64` plus matching pin labels is as far as verification goes until someone runs
the smoke test below on real arm64 hardware.

Smoke test on the machine that will run it: `rclone version` must report `go/linking: static`,
`help backends` must still list the fork additions, and `mount` must come up and serve a read and
a write. `rclone` is not installed on the targets, so everything below runs inside the container,
and `$IMG` must be a `name@digest` reference for the result to describe the pin. This is the shape
of the run that was green on 2026-11-16:

```
S=$HOME/bclone-smoke; mkdir -p "$S/src" "$S/m/mt" "$S/cfg"
echo probe > "$S/src/hello.txt"
printf 'rclone:x:%s:%s::/config:/bin/sh\n' "$(id -u)" "$(id -g)" > "$S/passwd"
docker run --rm -i --user "$(id -u):$(id -g)" \
  -e HOME=/config -e XDG_CONFIG_HOME=/config \
  -v "$S/passwd":/etc/passwd:ro -v "$S/cfg":/config/rclone \
  -v "$S/src":/data/src -v "$S/m":/mnt \
  --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
  --entrypoint sh "$IMG" -c '
    rclone version
    rclone help backends | grep -cE "teldrive|telegram|gotohp|alist|terabox"
    rclone --transfers 1 --buffer-size 8M mount /data/src /mnt/mt &
    PID=$!
    sleep 5; cat /mnt/mt/hello.txt; echo x > /mnt/mt/mark.txt; kill $PID'
cat "$S/src/mark.txt"          # must contain x: the write reached the host through the mount
```

Green run on 2026-11-16, amd64: `go/linking: static`, `go/tags: noselfupdate`, alpine 3.22.8, the
backends grep printed `5`, `hello.txt` read through the mount, `mark.txt` appeared on the host. The
one line to expect and ignore is `Config file "/config/rclone/rclone.conf" not found`, which is
what an empty scratch config dir looks like.

Six traps, all measured on the amd64 COS target, none of them obvious:
- `--security-opt apparmor=unconfined` or `fusermount3` dies with `mount failed: Permission denied`
  even with SYS_ADMIN.
- `--user` without the `/etc/passwd` bind dies with `could not determine username`; see the
  deployment notes for the root-with-`:ro` alternative.
- `--entrypoint sh`, not `sh -c` as an argument: the image entrypoint *is* `rclone`, so a bare
  `… "$IMG" sh -c …` asks rclone to run a remote named `sh`.
- `kill %1` does not work: the container's `sh` is non-interactive, so capture `$!` and kill that.
- The mount target must be an empty directory that is not itself a bind mountpoint (`/mnt/mt`
  under a bind of `/mnt`), and the previous run's `mark.txt` is still there: clear it or the next
  mount is refused as "not empty".
- A config section of `type = local` is not a usable mount source - rclone ignores its
  `remote =` value and exports the working directory, which looks like a successful mount that
  lists nothing. Mount a plain path, as above.
- Scratch dirs under `$HOME` are fine (noexec blocks executing them, not reading them); `/tmp`
  also works but is wiped on reboot.

## Digest log

One row per build. `digest` is always the **index** digest (see Architectures above), never a
per-platform one. `verdict` starts with the step-7 word, then says what was actually executed and
on which architecture; a row with no smoke test on it is a row nobody pinned yet.

| digest | fork revision | verdict | date |
|---|---|---|---|
| `sha256:45b7b7e421ef0d97095e4189e45c325ef1f3328a00a2cf4e1853d53079f50565` | `a90c73aab01c06769064f83a0954e1ca18d170b7` | SAFE-WITH-CONDITIONS (telegram stays unconfigured, `multi_thread_resume` stays off) - pulled anonymously on the free-tier e2-micro / COS target, 80 backends incl. every fork addition + `crypt` + `filen`, alpine 3.22.8, FUSE mount served a read and a write on `linux/amd64` | 2026-11-12 |

Re-checks of that same digest, so the row above does not have to imply them:
- 2026-11-16: `latest` and `v1.76.2-a90c73a` both still resolve to it; upstream fork tip and newest
  release still equal the pins, so nothing was owed. `linux/arm64` manifest and config inspected
  (correct architecture, same `org.opencontainers.image.revision`) but never executed. The documented
  smoke test re-run on the amd64 target as a non-root uid, read and write through the mount green.

Provenance: the workflow sets `provenance: true` and its log shows `exporting attestation
manifest` for both platforms, but the trust anchor here is the build itself - source fetched by
pinned SHA and verified against `BCLONE_TGZ_SHA256`. `gh attestation verify oci://<image>@<digest>`
needs gh >= 2.49 (2.46 has no `attestation` command), so treat it as optional extra assurance.

## Updating a target

There is no long-lived container to restart: each wrapper starts a fresh container per command, so
the only state on a target is the `IMG=` line in `/home/<user>/bclone/bc` and `/home/<user>/bclone/td`.
To move a target, therefore:

1. Edit `IMG=` to the new `name@digest` (the tag form is for humans; the wrapper should carry a
   digest so a silently re-pointed tag cannot change what runs).
2. `docker pull "$IMG"` once, explicitly, so a bad digest fails in front of you rather than on the
   first real transfer. Anonymous pull; no `docker login` for a public package.
3. Run the smoke test above against the new digest.
4. `sh /home/<user>/bclone/bc version` and one harmless `bc lsd <remote>:` through the wrapper, to
   prove the config binds and the pinned remote still exists.
5. Append the row to the digest log, and say so in the commit message of the docs change.

Rollback is step 1 with the old digest - nothing else on the target is stateful, though
`rclone.conf` is shared: a new build that rewrote config sections cannot be rolled back by pinning
the old image, so `--dump` the config to a dated copy in the bound config directory before testing
a major version.

Checked 2026-11-16: both wrappers pin the index digest from the row above on their `IMG=` line, and
`sh /home/<user>/bclone/bc version </dev/null` reports `rclone v1.76.2` on alpine 3.22.8 with
`go/linking: static`, so the target and the log agree today.


## Deployment notes for Container-Optimized OS targets
- `/home`, `/var`, `/tmp` are noexec: never bind-mount a binary and run it; run the image. The
  same blocks your own wrappers under `/home`, so call them as `sh /home/<user>/bclone/bc …`.
- The host `$HOME` is correct here (`/home/<user>`, checked with `printenv` in a transferred
  script). What is *not* trustworthy is measuring it through `ssh A "ssh B 'echo $HOME'"`: the
  local Git Bash expands `$HOME` before the remote ever sees it, which is how a Windows home
  path like `/c/Users/<name>` gets reported from a Linux box. Read remote values only through a
  base64-transferred script.
- A container started with `--user` has no passwd entry, so **inside** it `HOME` is `/` and
  rclone would look for `/.config/rclone/rclone.conf`. Pass
  `-e HOME=/config -e XDG_CONFIG_HOME=/config` and bind absolute host paths; the wrapper env is
  what makes `/config/rclone/rclone.conf` resolve. Without it rclone reports no remotes while
  the file sits on disk.
- Always pass `--user $(id -u):$(id -g)`, or the container writes root-owned config that the
  SSH user can no longer read. **Exception, measured 2026-11-16: `mount` does not work with
  `--user` alone.** `fusermount3` then exits `could not determine username`, because the uid has
  no passwd entry inside the image (the same absence that makes `HOME=/`). Two ways to mount:
  bind a one-line passwd entry for that uid (`printf 'rclone:x:UID:GID::/config:/bin/sh'` to a
  file, `-v that-file:/etc/passwd:ro`) and keep `--user`; or drop `--user`, run as root, and bind
  the config directory read-only (`:ro`) so nothing root-owned can be written into it. Both
  served a read and a write through the mount on the amd64 target; the root variant is what the
  2026-11-12 row in the digest table was verified with.
- Wrappers call `docker run -i`; any script calling a wrapper must add `</dev/null`, otherwise
  docker swallows the remainder of the script.
- Bind one config *directory* per purpose (`~/.config/rclone` for the shared remotes,
  `~/.config/rclone-td` for teldrive) so a container never sees credentials it does not need.
  The bind target is the directory **inside** the config root rclone was told to use:
  `-v /home/<user>/.config/rclone:/config/rclone`, because `XDG_CONFIG_HOME=/config` makes
  rclone read `/config/rclone/rclone.conf`. Binding it at `/config` instead hides the file.
- 1 GiB RAM: `--transfers 1 --checkers 4 --buffer-size 8M`, `--teldrive-chunk-size 64M`,
  `--filen-upload-concurrency 4`. The first three are backend-independent system options; the
  last two are per-backend remote options named with their backend prefix. Set them all as
  flags in the wrapper rather than in `rclone.conf`, after the image name but before `"$@"`:
  rclone honours the last occurrence, so a caller can still raise `--transfers` for one run.
- `rclone mount` needs `--device /dev/fuse --cap-add SYS_ADMIN`, plus
  `--security-opt apparmor=unconfined` on COS: its `docker-default` AppArmor profile makes
  `fusermount3` fail with `mount failed: Permission denied` even with SYS_ADMIN, and
  `seccomp=unconfined` or extra capabilities do not help. `--privileged` also works but is
  wider than needed. Verified again 2026-11-16 with a read and a write through the mount; that
  test also needs a uid inside the container that exists in `/etc/passwd` - see the `--user`
  bullet above, which is the part most likely to be missed.

