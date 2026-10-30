defmodule Arbor.Capabilities.Signals do
  @moduledoc "Explicit Signals provider backed by the canonical Capabilities authority."

  use Boundary, top_level?: true, deps: [Arbor.Security, Arbor.Signals], exports: []

  @behaviour Arbor.Signals.Contracts.Authorization
  @behaviour Arbor.Signals.Contracts.Crypto
  @behaviour Arbor.Signals.Contracts.IdentityKeys

  @impl Arbor.Signals.Contracts.Authorization
  defdelegate authorize(principal, resource, action, opts), to: Arbor.Security

  @impl Arbor.Signals.Contracts.IdentityKeys
  defdelegate lookup(agent_id), to: Arbor.Security
  @impl Arbor.Signals.Contracts.IdentityKeys
  defdelegate lookup_encryption_key(agent_id), to: Arbor.Security
  @impl Arbor.Signals.Contracts.Crypto
  defdelegate generate_encryption_keypair(), to: Arbor.Security
  @impl Arbor.Signals.Contracts.Crypto
  defdelegate encrypt(plaintext, key), to: Arbor.Security
  @impl Arbor.Signals.Contracts.Crypto
  defdelegate decrypt(ciphertext, key, iv, tag), to: Arbor.Security
  @impl Arbor.Signals.Contracts.Crypto
  defdelegate seal(plaintext, recipient_public, sender_private), to: Arbor.Security
  @impl Arbor.Signals.Contracts.Crypto
  defdelegate unseal(sealed, recipient_private, sender_public), to: Arbor.Security
end
