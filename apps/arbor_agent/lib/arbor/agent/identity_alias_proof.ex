defmodule Arbor.Agent.IdentityAliasProof do
  @moduledoc """
  Client-side possession proof for identity-alias management.

  The caller holds a `.arbor.key` file, builds a canonical payload bound to
  the exact mutation (operation + arguments), and signs with
  `Arbor.Contracts.Security.SignedRequest.sign/3`. The server only verifies.
  This module never loads a stored principal key and never asks the server
  to sign.

  `--as` is a claim of *which* key file to use. It never grants authority.
  """

  alias Arbor.Agent.IdentityAliasProofCore
  alias Arbor.Contracts.Security.SignedRequest

  @manage_resource "arbor://identity/alias/manage"
  @default_key_path "~/.arbor/operator.key"

  @doc "Resource URI the alias-management *capability* is bound to."
  @spec resource() :: String.t()
  def resource, do: @manage_resource

  @doc "Default operator key-file path (`~/.arbor/operator.key`)."
  @spec default_key_path() :: String.t()
  def default_key_path, do: Path.expand(@default_key_path)

  @doc """
  Resolve the key file path from CLI opts.

  `--key-file` wins; otherwise the default under `~/.arbor/`.
  """
  @spec key_file_path(keyword()) :: String.t()
  def key_file_path(opts) when is_list(opts) do
    case Keyword.get(opts, :key_file) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> default_key_path()
    end
  end

  @doc """
  Canonical mutation payload the server will reconstruct and require.

  Delegates to `IdentityAliasProofCore` so the byte layout can be tested
  without IO.
  """
  @spec canonical_payload(IdentityAliasProofCore.mutation() | term()) ::
          {:ok, binary()} | {:error, :invalid_mutation}
  defdelegate canonical_payload(mutation), to: IdentityAliasProofCore

  @doc """
  Sign the mutation-bound alias-management payload with caller-held key material.
  """
  @spec sign(Arbor.Security.key_file_material(), IdentityAliasProofCore.mutation()) ::
          {:ok, SignedRequest.t()} | {:error, term()}
  def sign(%{agent_id: agent_id, private_key: private_key}, mutation)
      when is_binary(agent_id) and is_binary(private_key) do
    with {:ok, payload} <- IdentityAliasProofCore.canonical_payload(mutation) do
      SignedRequest.sign(payload, agent_id, private_key)
    end
  end

  def sign(_, _), do: {:error, :invalid_key_material}

  @doc """
  Read the caller-held key file and sign as the principal recorded in it.

  This is the default CLI path when `--as` is omitted. Returning the resolved
  principal alongside the proof keeps the caller id and signature sourced from
  the same key-file read.
  """
  @spec prove(Path.t(), IdentityAliasProofCore.mutation()) ::
          {:ok, String.t(), SignedRequest.t()} | {:error, term()}
  def prove(path, mutation) when is_binary(path) do
    with {:ok, payload} <- IdentityAliasProofCore.canonical_payload(mutation) do
      Arbor.Security.sign_key_file_request(path, payload)
    end
  end

  def prove(_path, _mutation), do: {:error, :invalid_proof_args}

  @doc """
  Read a key file the caller holds and produce a mutation-bound SignedRequest.

  `claimed_principal_id` is the `--as` (or default) claim of *which* key
  file to use. It never grants authority: a mismatch with the file's
  principal fails closed.
  """
  @spec prove(Path.t(), String.t(), IdentityAliasProofCore.mutation()) ::
          {:ok, SignedRequest.t()} | {:error, term()}
  def prove(path, claimed_principal_id, mutation)
      when is_binary(path) and is_binary(claimed_principal_id) do
    with {:ok, actual_principal_id, signed_request} <- prove(path, mutation),
         :ok <- assert_claimed_identity(actual_principal_id, claimed_principal_id) do
      {:ok, signed_request}
    end
  end

  def prove(_path, _claimed_principal_id, _mutation), do: {:error, :invalid_proof_args}

  defp assert_claimed_identity(actual, claimed) when actual == claimed, do: :ok

  defp assert_claimed_identity(actual, claimed),
    do: {:error, {:principal_mismatch, claimed, actual}}
end
