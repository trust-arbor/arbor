defmodule Arbor.Security.Contracts.PrivateMemoryRecord do
  @moduledoc false
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Security.Crypto
  alias Arbor.Security.PrivateMemory

  @fields ~w(agent_id human_id engagement_id session_id turn_id id source_namespace source_key
    body_digest vector_digest model_id dimensions encoding category generation revision tombstone)
  @scalars ~w(agent_id human_id engagement_id session_id turn_id id source_namespace source_key model_id)
  @stamp_fields ~w(version issuer_id signature descriptor_digest)
  @domain "arbor.private-memory-record.v1\0"
  @fixed %{
    "encoding" => "ieee754_float32_be_v1",
    "category" => "conversation",
    "generation" => 1,
    "revision" => 1,
    "tombstone" => false
  }

  def admit(descriptor) when is_map(descriptor) do
    with true <- Enum.sort(Map.keys(descriptor)) == Enum.sort(@fields),
         true <- Enum.all?(@scalars, &PrivateMemory.scalar?(Map.get(descriptor, &1))),
         true <- Enum.all?(@fixed, fn {key, value} -> Map.get(descriptor, key) === value end),
         true <- vector_descriptor?(descriptor) do
      :ok
    else
      _ -> {:error, :invalid_memory_record}
    end
  end

  def admit(_), do: {:error, :invalid_memory_record}

  def scope_matches?(descriptor, scope) do
    Enum.all?([:agent_id, :human_id, :engagement_id, :session_id, :turn_id], fn key ->
      Map.get(descriptor, Atom.to_string(key)) == Map.fetch!(scope, key)
    end)
  end

  def sign(descriptor, identity) do
    with :ok <- admit(descriptor), {:ok, digest} <- descriptor_digest(descriptor) do
      payload = payload(identity.agent_id, digest)

      {:ok,
       %{
         "version" => 1,
         "issuer_id" => identity.agent_id,
         "descriptor_digest" => digest,
         "signature" => Base.encode64(Crypto.sign(payload, identity.private_key))
       }}
    end
  end

  def verify(descriptor, stamp, identity) when is_map(stamp) do
    with :ok <- admit(descriptor),
         true <- Enum.sort(Map.keys(stamp)) == Enum.sort(@stamp_fields),
         true <- stamp["version"] === 1 and stamp["issuer_id"] == identity.agent_id,
         {:ok, digest} <- descriptor_digest(descriptor),
         true <- stamp["descriptor_digest"] == digest,
         signature when is_binary(signature) and byte_size(signature) == 88 <- stamp["signature"],
         {:ok, bytes} when byte_size(bytes) == 64 <- Base.decode64(signature),
         true <- Base.encode64(bytes) == signature,
         true <- Crypto.verify(payload(identity.agent_id, digest), bytes, identity.public_key) do
      :ok
    else
      _ -> {:error, :invalid_memory_record}
    end
  rescue
    _ -> {:error, :invalid_memory_record}
  end

  def verify(_, _, _), do: {:error, :invalid_memory_record}

  defp descriptor_digest(descriptor) do
    with {:ok, bytes} <- TaintEnvelope.canonical_json(descriptor),
         do: {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  defp payload(issuer, digest), do: @domain <> issuer <> "\0" <> digest

  defp vector_descriptor?(descriptor) do
    digest?(descriptor["body_digest"]) and digest?(descriptor["vector_digest"]) and
      is_integer(descriptor["dimensions"]) and descriptor["dimensions"] in 1..65_536
  end

  defp digest?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp digest?(_), do: false
end
