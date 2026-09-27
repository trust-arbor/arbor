# Validation runtime image

Reviewed OCI image for Linux spawn-containment (`org.arbor.validation.role=spawn-containment`).

Guest toolchain roots match `OciPlanCore`:

| Tool | Guest path |
|---|---|
| Erlang/OTP | `/usr/local/lib/erlang` |
| Elixir | `/usr/local` |
| `MIX_HOME` | `/usr/local/.mix` |
| `MIX_ARCHIVES` | `/usr/local/.mix/archives` |
| `ELIXIR_MAKE_CACHE_DIR` | `/usr/local/.cache/elixir_make` |

The Arbor Mix wrapper is **not** in this image. Production create argv bind-mounts the host wrapper at `/arbor/bin/mix`.

The image builds checksum-pinned PortAudio 19.7.0 against pinned Debian ALSA and
pkgconf packages. Bundlex uses this pkg-config installation; the repository
disables the PortAudio plugin's precompiled OS dependency downloads. Existing
Exqlite and lazy_html archives are checksum-pinned in the image-owned NIF cache.
See [native admission evidence](../../docs/arbor/VOICE_MULTIMEDIA_ADMISSION.md)
for the qualified ARM64 image, dependency receipt and pending live activation.

`git` is installed so Mix can run `Mix.SCM.Git.lock_status` against git-dep
checkouts in the sources-only baseline (`jido_sandbox/.git` and similar). The
baseline tree pin is unchanged; only the image needs rebuild/activate.

## Closed platforms

Native arch only. `linux/amd64` or `linux/arm64`. No qemu-user translation.

## Operator preflight

Builds pass `--pull=never` for the **base** image. Pull it once:

```
podman pull debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171
```

Then:

```
mix arbor.baseline.build
mix arbor.baseline.activate <tree-digest>
```

Restart the Arbor node so `config/runtime.exs` re-pins `$ARBOR_HOME/validation-runtime.json`.

Toolchain ARG defaults must match `.tool-versions`. The drift test parses both
and requires a digest-pinned `FROM` plus `sha256sum -c` for the OTP and Elixir
archives; do not hardcode a third copy of the version strings.
