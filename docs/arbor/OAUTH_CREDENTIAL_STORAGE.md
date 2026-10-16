# OAuth credential storage

**State reviewed:** 2026-10-16

Arbor-owned OpenAI and xAI OAuth envelopes are stored through an optional
backend. Same-user malware that can read `~/.arbor/oauth/*.json` is the
class of theft described in the [Warden Stealer analysis](https://yaamlabs.com/blog/warden-stealer-ai-agent-data).
Mode `0600` on a plaintext JSON file does not stop that reader.

## Backends

| Backend | What is on disk | Where the secret lives |
|---|---|---|
| `:file` (default) | `~/.arbor/oauth/<provider>.json` at mode `0600` | The JSON file itself |
| `:keyring` | No plaintext token file | macOS Keychain (`security`) or Linux libsecret (`secret-tool`) |
| `:encrypted_file` | `~/.arbor/oauth/<provider>.enc` (AES-256-GCM JSON envelope, mode `0600`) | Ciphertext on disk; 32-byte DEK in the keyring |

The file backend is unchanged and remains the default so existing hosts keep
working. Keyring and encrypted-file are opt-in.

## Configuration

Application env (compiled/config):

```elixir
config :arbor_llm, oauth_storage_backend: :file
# config :arbor_llm, oauth_storage_backend: :keyring
# config :arbor_llm, oauth_storage_backend: :encrypted_file
```

Runtime env (ignored under `MIX_ENV=test`):

```bash
export ARBOR_OAUTH_STORAGE=keyring          # or file | encrypted_file
```

Linux keyring storage needs `secret-tool` (the `libsecret-tools` package on
Debian/Ubuntu). macOS uses the built-in `/usr/bin/security` tool. Secrets are
passed on stdin, never on argv.

An invalid `ARBOR_OAUTH_STORAGE` value fails closed at runtime rather than
falling back to a plaintext file.

## Migration

When `:keyring` or `:encrypted_file` is enabled and a leftover plaintext
`<provider>.json` exists:

1. The envelope is copied into the new backend.
2. The plaintext file is overwritten with zeros and deleted.
3. Later reads use only the new backend.

If the keyring write fails, the plaintext file is left unchanged. If the
keyring write succeeds but the plaintext file cannot be removed, the operation
fails closed so a leftover token file is not treated as a successful hardening.

## Test adapter

Tests inject `Arbor.LLM.OAuth.Keyring.Memory` through
`:oauth_keyring_adapter`. CI does not need a real Keychain or libsecret.

## What this does not cover

- Windows Credential Manager (file backend remains the default there).
- A live macOS Keychain or Linux Secret Service round-trip in CI.
- Codex/Grok CLI credential files. Arbor does not copy those rotating refresh
  tokens into `~/.arbor/oauth`.
