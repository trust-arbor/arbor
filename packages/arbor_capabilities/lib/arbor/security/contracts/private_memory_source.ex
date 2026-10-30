defmodule Arbor.Security.Contracts.PrivateMemorySource do
  @moduledoc false

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Security.Contracts.PrivateMemoryRecord
  alias Arbor.Security.{Crypto, PrivateMemory}

  @scope ~w(agent_id human_id engagement_id session_id turn_id)
  @fields @scope ++ ~w(source_id id source_namespace source_key body_digest user_role
    user_content_digest assistant_role assistant_content_digest)
  @bound @scope ++ ~w(id source_namespace source_key body_digest)
  @digests ~w(body_digest user_content_digest assistant_content_digest)
  @stamp_fields ~w(version issuer_id signature descriptor_digest)
  @domain "arbor.private-memory-source.v1\0"

  def admit(descriptor) when is_map(descriptor) and not is_struct(descriptor) do
    with true <- map_size(descriptor) == length(@fields),
         true <- Enum.sort(Map.keys(descriptor)) == Enum.sort(@fields),
         true <- Enum.all?(@scope, &PrivateMemory.scalar?(descriptor[&1])),
         true <- Enum.all?(@digests, &digest?(descriptor[&1])),
         true <- descriptor["user_role"] == "user" and descriptor["assistant_role"] == "assistant",
         true <- descriptor["source_id"] == "session_turn:" <> descriptor["turn_id"],
         true <- PrivateMemory.scalar?(descriptor["source_id"]),
         {:ok, pair} <-
           VectorRecord.payload_digest([descriptor["agent_id"], descriptor["human_id"]]),
         {:ok, row} <-
           VectorRecord.payload_digest([
             descriptor["agent_id"],
             descriptor["human_id"],
             descriptor["source_id"]
           ]),
         true <- descriptor["source_namespace"] == "private_conversation_" <> pair,
         true <- descriptor["id"] == "private_mem_" <> row,
         true <- descriptor["source_key"] == descriptor["id"] do
      :ok
    else
      _ -> {:error, :invalid_memory_source}
    end
  end

  def admit(_), do: {:error, :invalid_memory_source}

  def scope_matches?(descriptor, scope), do: PrivateMemoryRecord.scope_matches?(descriptor, scope)

  def pair_matches?(descriptor, scope),
    do: descriptor["agent_id"] == scope.agent_id and descriptor["human_id"] == scope.human_id

  def binds_record?(source, record) do
    admit(source) == :ok and PrivateMemoryRecord.admit(record) == :ok and
      Enum.all?(@bound, &(source[&1] === record[&1]))
  end

  def sign(descriptor, identity) do
    with :ok <- admit(descriptor), {:ok, digest} <- descriptor_digest(descriptor) do
      {:ok,
       %{
         "version" => 1,
         "issuer_id" => identity.agent_id,
         "descriptor_digest" => digest,
         "signature" =>
           Base.encode64(Crypto.sign(payload(identity.agent_id, digest), identity.private_key))
       }}
    end
  end

  def verify(descriptor, stamp, identity) when is_map(stamp) and not is_struct(stamp) do
    with :ok <- admit(descriptor),
         true <- map_size(stamp) == length(@stamp_fields),
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
      _ -> {:error, :invalid_memory_source}
    end
  rescue
    _ -> {:error, :invalid_memory_source}
  end

  def verify(_, _, _), do: {:error, :invalid_memory_source}

  defp descriptor_digest(descriptor) do
    with {:ok, bytes} <- TaintEnvelope.canonical_json(descriptor),
         do: {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  defp payload(issuer, digest), do: @domain <> issuer <> "\0" <> digest

  defp digest?(value) when is_binary(value),
    do: byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp digest?(_), do: false
end
