defmodule Arbor.Agent.IdentityAliasProofCore do
  @moduledoc """
  Pure canonical payload for identity-alias possession proofs.

  Domain-separated and length-prefixed so two distinct mutations cannot
  collapse to the same bytes. `IdentityAliases` reconstructs this from the
  arguments it is about to act on; the verifier never takes the payload
  from the caller.

  ## Byte layout

  Every field is `<<byte_size::32-big, field::binary>>`:

      link:   version | "link"   | secondary_id | primary_id
      unlink: version | "unlink" | secondary_id

  `version` is `"arbor.identity.alias.v1"`. The version tag and the
  operation tag are what stop a `link` proof from being replayed as an
  `unlink`. Length-prefixing is what stops concatenating different
  arguments from producing identical bytes.
  """

  @version "arbor.identity.alias.v1"

  @typedoc "Mutation the possession proof is bound to."
  @type mutation :: {:link, String.t(), String.t()} | {:unlink, String.t()}

  @doc "Domain-separated version tag included as the first payload field."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Build the canonical signed payload for a mutation.

  Returns `{:ok, payload}` or `{:error, :invalid_mutation}`.
  """
  @spec canonical_payload(mutation() | term()) :: {:ok, binary()} | {:error, :invalid_mutation}
  def canonical_payload({:link, secondary_id, primary_id})
      when is_binary(secondary_id) and is_binary(primary_id) and
             byte_size(secondary_id) > 0 and byte_size(primary_id) > 0 do
    {:ok, encode([@version, "link", secondary_id, primary_id])}
  end

  def canonical_payload({:unlink, secondary_id})
      when is_binary(secondary_id) and byte_size(secondary_id) > 0 do
    {:ok, encode([@version, "unlink", secondary_id])}
  end

  def canonical_payload(_), do: {:error, :invalid_mutation}

  defp encode(fields) do
    Enum.reduce(fields, <<>>, fn field, acc -> acc <> length_prefix(field) end)
  end

  defp length_prefix(field) when is_binary(field) do
    <<byte_size(field)::32-big, field::binary>>
  end
end
