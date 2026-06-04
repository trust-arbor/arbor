# Operator Identity & Checkpoint Integrity

This document covers the operator identity key used by `mix arbor.pipeline.run` and `mix arbor.pipeline.resume`, why it's required, and how to generate / install one.

## Why an identity key

Engine checkpoints are HMAC-signed using a secret derived from the operator's Ed25519 private key (HKDF, RFC 5869, domain-separated by the label `"arbor-checkpoint-hmac-v1"`). On resume, the engine re-derives the same secret from the same key and verifies the HMAC. This guarantees:

- A checkpoint can only be resumed by the operator who started the run.
- A checkpoint forged by an agent with FS-write access to `logs_root` is rejected, because the agent doesn't have the operator's private key.
- An attempted replay with a checkpoint from a different operator's run is rejected, because the derived secret won't match.

Without identity, resume fails immediately with `{:error, :identity_required_for_resume}`. See `.arbor/roadmap/5-completed/security-checkpoints-unverified-by-default.md` for the threat model and design.

## Key resolution order

CLI tasks resolve the identity key from the first matching source:

1. `--identity-key <path>` — explicit per-invocation flag
2. `ARBOR_KEY=<path>` — environment variable, useful for shell sessions or CI
3. `~/.arbor/identity.key` — default location

If none of these contain a valid key, the task halts with a clear error.

## Key file format

Plain-text, line-oriented, parsed by `Arbor.Gateway.Signer.ProxyCore.parse_key_file/1`:

```
agent_id=agent_30b455a27f7f4e02ef291fd9f7862677f731a1f8b08c997f5fb8ad430d594b6e
private_key_b64=BASE64ENCODEDKEYBYTES==
```

Required fields:

- `agent_id` — string starting with `agent_` followed by 64 lowercase hex chars. Derived from the public key as `"agent_" <> hex(SHA-256(pubkey))`.
- `private_key_b64` — base64-encoded Ed25519 private key. Accepted lengths: 32 bytes (seed) or 64 bytes (Erlang's expanded form from `:crypto.generate_key(:eddsa, :ed25519)`).

Lines that don't match `key=value` are ignored. Extra fields are tolerated.

## Generating a new identity

There's no dedicated CLI task yet; generate via the Elixir API. From `iex -S mix` or a one-off script:

```elixir
alias Arbor.Contracts.Security.Identity

{:ok, identity} = Identity.generate(name: "my-operator-name")

contents = """
agent_id=#{identity.agent_id}
private_key_b64=#{Base.encode64(identity.private_key)}
"""

path = Path.expand("~/.arbor/identity.key")
File.mkdir_p!(Path.dirname(path))
File.write!(path, contents)
File.chmod!(path, 0o600)

IO.puts("Wrote identity for #{identity.agent_id} to #{path}")
```

## What the 0600 chmod does and does not defend

The `chmod 0600` makes the file unreadable by **other unix users** on the host. Concretely:

- Defends against: a different unix user on the box (`postgres`, `nobody`, a co-tenant on a shared system) reading the key.
- Defends against: backup tools / dotfile-sync utilities running under a different UID picking the file up with permissive default perms.
- Does **not** defend against: code running inside any process owned by the same UID as the file owner — including the Arbor BEAM, any agent running inside that BEAM, any shell command invoked by `arbor://shell/exec/*` capabilities, and any other tool you run from your normal shell.

For the agent-in-BEAM threat — an Arbor agent with shell-exec capabilities calling `cat ~/.arbor/identity.key` — the unix perm bit is irrelevant. The shell process inherits your UID and the OS lets it through. The real defenses against that threat are Arbor's own:

1. **Capability scope** — don't grant agents `arbor://shell/exec/cat` (or `arbor://fs/read/.arbor/**`) unless they need it. The cap shape is the load-bearing line.
2. **Shell sandbox path constraints** — the shell handler's allowlist + path checks (see `Arbor.Shell.Sandbox`).
3. **FileGuard wiring through the auth chain** — currently partial; `Security.authorize/4` only invokes FileGuard when callers pass `:file_path`, and most production callers don't. Tracked as a defense-in-depth follow-up.

So: keep the 0600 chmod (it's free hygiene for the scenarios it addresses), but understand that on a single-user dev box it's mostly insurance for future contexts. The threats that matter today are inside Arbor's own trust boundary, and the defense lives in capability shape, not file perms.

## Installing an existing identity at the default path

If you already have an Arbor identity at another location (e.g., the legacy `~/.claude/arbor-personal/<name>.arbor.key`), symlink it to the default path so CLI tasks pick it up automatically:

```sh
ln -s ~/.claude/arbor-personal/<name>.arbor.key ~/.arbor/identity.key
```

A symlink works because the helper resolves `Path.expand("~/.arbor/identity.key")` and reads through to the target.

## Multiple identities

For operators with multiple identities (e.g., different identities for different projects), the cleanest pattern is to leave `~/.arbor/identity.key` unset and explicitly pass `--identity-key` or `ARBOR_KEY` per invocation:

```sh
# Per command
mix arbor.pipeline.run pipeline.dot --identity-key ~/.arbor/project_a.key

# Per shell
export ARBOR_KEY=~/.arbor/project_b.key
mix arbor.pipeline.run pipeline.dot
```

Each identity produces a distinct HMAC secret, so checkpoints written under one identity can only be resumed under the same identity. This is intentional — switching identities mid-run is not a supported operation.

## What's in scope today vs. follow-ups

Currently identity-aware:

- `mix arbor.pipeline.run` — signs checkpoints, fails if no identity
- `mix arbor.pipeline.resume` — verifies HMAC, fails if no identity OR identity doesn't match

Not wired, by design:

- `mix arbor.pipeline.benchmark` — benchmarking workload. Already has `--no-checkpoint` for overhead measurement. Resume isn't a normal operational mode.
- `mix arbor.pipeline.eval` — eval runs (accuracy testing, model comparison) are run-to-completion. Eval failures get rerun from scratch with adjusted parameters, not resumed.

Not yet wired, real follow-up:

- `mix arbor.orchestrate` — uses OIDC auth via `Arbor.Security.authenticate_oidc_token` which returns `{agent_id, signer}` without exposing the underlying private key. Wiring `:identity_private_key` here needs a design call: either refactor `authenticate_oidc_token` to also return the key, OR load file-based identity in parallel with OIDC (and pick which identity binds the HMAC). Not mechanical; touches the auth composition between OIDC and file-based identity.

## Related

- `apps/arbor_orchestrator/lib/arbor/orchestrator/mix/helpers.ex` — `load_identity/1`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/engine.ex` — `derive_checkpoint_hmac_secret/1`, `require_identity_on_resume/1`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/engine/checkpoint.ex` — `sign/3`, `verify/3` (HMAC-SHA256 with AAD bound to `run_id` + `current_node` + `graph_hash`)
- `apps/arbor_contracts/lib/arbor/contracts/security/identity.ex` — `Identity.generate/1`
- `apps/arbor_security/lib/arbor/security/crypto.ex` — `derive_key/3` (HKDF, RFC 5869)
- `apps/arbor_gateway/lib/arbor/gateway/signer/proxy_core.ex` — `parse_key_file/1`
