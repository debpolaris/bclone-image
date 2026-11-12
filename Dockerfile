# Single source of truth for pins. Change these, then re-run AUDIT_RUNBOOK.md.
ARG BCLONE_REV=a90c73aab01c06769064f83a0954e1ca18d170b7
ARG BCLONE_TGZ_SHA256=40de668b42d21a822a939a89cd9d05a0347604d375e1d1a8f8d44cec6de7edf4
ARG BCLONE_VERSION=v1.76.2
ARG RCLONE_BASE=ba11197157fe590b581393e801e2b1721fb4d608

FROM --platform=$BUILDPLATFORM golang:1.26-alpine@sha256:30b1e546a9c7fa3b747c2bdba3a0c7bdf3a02ebb4c5b8405d2f948d7e8aac4ec AS build
ARG BCLONE_REV BCLONE_TGZ_SHA256 BCLONE_VERSION
ARG TARGETOS TARGETARCH
RUN apk add --no-cache curl
WORKDIR /src
RUN curl -fsSL -o src.tgz "https://codeload.github.com/BenjiThatFoxGuy/bclone/tar.gz/${BCLONE_REV}" \
  && echo "${BCLONE_TGZ_SHA256}  src.tgz" | sha256sum -c - \
  && tar xzf src.tgz --strip-components=1
# go.sum is present, so module hashes are checked against sum.golang.org during download.
RUN go mod download && go mod verify
# cmount keeps `rclone mount` working: cgofuse reaches libfuse through purego, so cgo stays off.
# noselfupdate matches upstream release builds and suits a digest-pinned image.
# -s and -trimpath are what the fork's own release pipeline already uses.
ENV CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH}
RUN go build -trimpath -tags "cmount,noselfupdate" \
      --ldflags "-s -X github.com/rclone/rclone/fs.Version=${BCLONE_VERSION}" \
      -o /rclone .

FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
ARG BCLONE_REV BCLONE_VERSION RCLONE_BASE
RUN apk --no-cache add ca-certificates fuse3 mailcap tzdata \
  && echo "user_allow_other" >> /etc/fuse.conf
COPY --from=build /rclone /usr/local/bin/rclone
ENV XDG_CONFIG_HOME=/config
WORKDIR /data
ENTRYPOINT ["rclone"]
LABEL org.opencontainers.image.title="bclone" \
  org.opencontainers.image.version="${BCLONE_VERSION}" \
  org.opencontainers.image.source="https://github.com/BenjiThatFoxGuy/bclone" \
  org.opencontainers.image.revision="${BCLONE_REV}" \
  org.opencontainers.image.base.digest="sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f" \
  io.github.bclone.upstream-rclone-commit="${RCLONE_BASE}" \
  io.github.bclone.audit="AUDIT_RUNBOOK.md"
