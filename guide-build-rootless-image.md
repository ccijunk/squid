# Build & Push Squid image (v7.7.1, source-built)

Tag: `swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/squid-cache/squid:v7.7.1`

This guide is modelled on the buildkit-proxy image guide. It builds a Squid
caching-proxy image from source (branch `v7` + [PR 2401](https://github.com/squid-cache/squid/pull/2401))
and pushes it to Huawei SWR.

## How it works

Running `docker buildx build --target <stage>` triggers a chain of Dockerfile stages. Here is what happens end-to-end.

### 1. Dockerfile stage dependency chain

```
ubuntu:24.04 (build)
  └── build           # apt: autoconf, automake, libtool, build-essential, perl,
                      #      libssl-dev, libcap-dev, libkrb5-dev, libldap2-dev,
                      #      libpam0g-dev, libxml2-dev, pkg-config
                      #  1. sed configure.ac      → bake 7.7.1 into the version
                      #  2. ./bootstrap.sh        → generate ./configure
                      #  3. ./configure --with-openssl ... → Makefiles
                      #  4. make -j$(nproc) && make install → /usr/local/squid

squid  (ubuntu:24.04)                          ← --target squid
  ├── apt: runtime libs only (ca-certificates, openssl, libssl3, libcap2,
  │        libxml2, libkrb5-3, libldap2, libpam0g)
  ├── COPY --from=build /usr/local/squid → /usr/local/squid
  ├── COPY squid.conf      → /etc/squid/squid.conf
  ├── COPY entrypoint.sh   → /entrypoint.sh
  ├── USER squid (uid 3128)
  └── ENTRYPOINT ["/entrypoint.sh"]            # squid -z init then squid -N
```

### 2. Cross-compilation: full native build per-arch (no `xx`)

The buildkit image uses [tonistiigi/xx](https://github.com/tonistiigi/xx) to
cross-compile Go binaries for `$TARGETPLATFORM` while the build itself runs on
`$BUILDPLATFORM` (an `amd64` host produces `linux/arm64` Go binaries natively,
without QEMU at compile time).

Squid is C++/autotools, so there is no `xx`-style cross-compilation here.
Buildx instead runs the **entire build stage inside a container for every target
architecture**. Non-native architectures (e.g. `arm64` on an `amd64` host) are
emulated under QEMU/binfmt, so those builds are slower. **QEMU is mandatory for
multi-arch Squid builds.**

### 3. Version stamping

- buildkit mounts `.git` (via `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`) and stamps
  `version.Version`, `version.Revision`, `version.Package` from `git describe`.
- Squid's version comes from `configure.ac` (`AC_INIT(...,[7.7-VCS],...)`).
  The Dockerfile `sed`s that string to `7.7.1` **before** running
  `./bootstrap.sh`, so the resulting binary reports
  `Squid Cache: Version 7.7.1` in `squid -v`.
- Override at build time with `--build-arg SQUID_VERSION=<version>`.

### 4. Why `oci-mediatypes=false` is required for SWR

Buildx ≥ 0.10 defaults to OCI media types for all output:

| Schema | Manifest type | Index (multi-arch) type |
|---|---|---|
| OCI (Buildx default) | `application/vnd.oci.image.manifest.v1+json` | `application/vnd.oci.image.index.v1+json` |
| Docker v2 (SWR-compatible) | `application/vnd.docker.distribution.manifest.v2+json` | `application/vnd.docker.distribution.manifest.list.v2+json` |

Huawei SWR accepts single OCI manifests but rejects OCI Index (multi-arch
manifest lists), returning `Invalid image, fail to parse 'manifest.json'`.
Passing `oci-mediatypes=false` in `--output` forces Buildx to emit Docker v2
media types, which SWR handles correctly.

---

## Prerequisites

- Docker with Buildx
- SWR login done beforehand

```bash
docker login swr.cn-southwest-2.myhuaweicloud.com
```

---

## Step 0: Prepare the source (v7 + PR 2401)

```bash
cd self-squid

# Branch v7 (7.7-VCS) tracking the upstream v7 maintenance branch
git checkout -b v7 upstream/v7

# Bug 5538: Do not update Content-Length from 304 responses (PR #2401)
# https://github.com/squid-cache/squid/pull/2401
# The PR is based on master; apply the two-file diff manually on v7:
git apply /path/to/2401.diff
#   src/HttpHeader.cc  → skipUpdateHeader() now also skips HdrType::CONTENT_LENGTH
#   CONTRIBUTORS       → add Baolin Zhu

# Confirm
git diff 173863d3ec -- src/HttpHeader.cc CONTRIBUTORS
```

The patch (already committed on the `v7` branch as `20e1b93a76`):

```diff
--- a/src/HttpHeader.cc
+++ b/src/HttpHeader.cc
@@ -260,7 +260,11 @@ HttpHeader::skipUpdateHeader(const Http::HdrType id) const
     return
         // TODO: Consider updating Vary headers after comparing the magnitude of
         // the required changes (and/or cache losses) with compliance gains.
-        (id == Http::HdrType::VARY);
+        (id == Http::HdrType::VARY) ||
+        // RFC 9111 Section 3.2 explicitly excludes Content-Length
+        // from the "MUST add ..., replacing already present" list. Also,
+        // broken servers are known to send Content-Length:0 in their 304s.
+        (id == Http::HdrType::CONTENT_LENGTH);
 }
```

---

## Step 1: Create the builder

The default `docker` driver cannot build multi-arch images or push multi-arch
manifests. Always use a `docker-container` driver builder.

Many environments (VMs, containers with restricted capabilities) cannot create
veth pairs for bridge networks, causing:

```
failed to add the host (vethXXX) <=> sandbox (vethYYY) pair interfaces: operation not supported
```

`--driver-opt network=host` runs the BuildKit container on the host network
directly, bypassing veth/bridge creation entirely.

```bash
docker buildx rm mp-builder 2>/dev/null || true

docker buildx create \
  --name mp-builder \
  --driver docker-container \
  --driver-opt network=host \
  --use

docker buildx inspect --bootstrap
# Status: running
# BuildKit version: v0.31.x
# Platforms: linux/amd64, linux/amd64/v2, linux/amd64/v3, linux/386
```

---

## Option A: amd64 only (no QEMU needed)

```bash
cd self-squid

SWR_TAG=swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/squid-cache/squid:v7.7.1

docker buildx build \
  --target squid \
  --platform linux/amd64 \
  --tag "${SWR_TAG}" \
  --build-arg SQUID_VERSION=7.7.1 \
  --provenance=false \
  --sbom=false \
  --output "type=image,push=true,oci-mediatypes=false" \
  .
```

---

## Option B: multi-arch amd64 + arm64 (QEMU required)

### 1. Register QEMU for arm64

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64

# Confirm arm64 is now listed
docker buildx inspect mp-builder
# Platforms: linux/amd64, linux/amd64/v2, linux/amd64/v3, linux/386, linux/arm64
```

### 2. Build and push

> Squid compiles the entire C++ tree natively inside QEMU for `arm64`, so this
> build takes noticeably longer than the amd64-only build.

```bash
cd self-squid

SWR_TAG=swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/squid-cache/squid:v7.7.1

docker buildx build \
  --target squid \
  --platform linux/amd64,linux/arm64 \
  --tag "${SWR_TAG}" \
  --build-arg SQUID_VERSION=7.7.1 \
  --provenance=false \
  --sbom=false \
  --output "type=image,push=true,oci-mediatypes=false" \
  .
```

---

## Target comparison

| Target | Stage | User | Entrypoint | Purpose |
|---|---|---|---|---|
| `build` | compile Squid from source | root | n/a | autotools build → `/usr/local/squid` |
| `squid` | minimal runtime | `squid` (uid 3128) | `entrypoint.sh` | runnable proxy image |

**Flag reference:**

| Flag | Why |
|---|---|
| `--target squid` | Stop at the runtime stage (slim image, no compiler/autotools) |
| `--build-arg SQUID_VERSION=7.7.1` | Stamp the version into `configure.ac` so `squid -v` reports `7.7.1` |
| `--platform linux/amd64,linux/arm64` | Build for both architectures and combine into a multi-arch manifest list |
| `--provenance=false --sbom=false` | Disable SLSA provenance and SBOM attestation manifests that Buildx attaches by default — these are OCI-only and cause SWR parse errors |
| `--output "type=image,push=true,oci-mediatypes=false"` | Push directly to the registry using Docker v2 media types instead of OCI; `oci-mediatypes=false` is the key flag that makes the multi-arch manifest list parseable by SWR |

---

## Verify

```bash
# Check the manifest list in the registry
docker buildx imagetools inspect \
  swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/squid-cache/squid:v7.7.1

# Pull and run the amd64 image
docker run --rm --platform linux/amd64 \
  swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/squid-cache/squid:v7.7.1 \
  /usr/local/squid/sbin/squid -v

# Pull and run the arm64 image
docker run --rm --platform linux/arm64 \
  swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/squid-cache/squid:v7.7.1 \
  /usr/local/squid/sbin/squid -v

# Smoke test the proxy (host port 3128 -> container 3128)
docker run -d --name squid -p 3128:3128 \
  swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/squid-cache/squid:v7.7.1
curl -x http://127.0.0.1:3128 -sI https://example.com -o /dev/null -w '%{http_code}\n'
docker logs squid
```

Expected `squid -v` output contains `Squid Cache: Version 7.7.1`.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `operation not supported` on veth/bridge | Recreate builder with `--driver-opt network=host` |
| `Invalid image, fail to parse 'manifest.json'` | Add `oci-mediatypes=false` to `--output`; SWR cannot parse OCI Index format |
| `exporting attestation manifest` still appears | Add `--provenance=false --sbom=false` explicitly |
| Only `linux/amd64` in builder platforms | Register QEMU: `docker run --privileged --rm tonistiigi/binfmt --install arm64` |
| `exec format error` running the image | Wrong arch loaded; verify with `docker inspect --format '{{.Architecture}}'` |
| `squid -v` reports `7.7-VCS` instead of `7.7.1` | Missing/incorrect `--build-arg SQUID_VERSION=7.7.1`, or the `sed` pattern did not match `[7.7-VCS]` in `configure.ac` |
| `Could not create directory /var/cache/squid/00` at startup | Cache dir not initialized or not writable by uid 3128; `entrypoint.sh` runs `squid -z` on start — check ownership with `docker exec ... ls -ld /var/cache/squid` |
| `configure: error: libssl headers not found` | `libssl-dev` missing in the `build` stage (only runtime `libssl3` is in the final image) |
| Slow GitHub/registry downloads during build | Unset `HTTP_PROXY`/`HTTPS_PROXY` if squid CA is not trusted in the build env, or pass squid CA via `--build-arg` |
