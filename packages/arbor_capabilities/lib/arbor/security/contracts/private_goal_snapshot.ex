defmodule Arbor.Security.Contracts.PrivateGoalSnapshot do
  @moduledoc false

  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Security.Crypto
  alias Arbor.Security.PrivateMemory

  @fields ~w(agent_id human_id engagement_id session_id turn_id id namespace key body_digest snapshot_revision)
  @scope_fields [:agent_id, :human_id, :engagement_id, :session_id, :turn_id]
  @stamp_fields ~w(version issuer_id signature descriptor_digest)
  @domain "arbor.private-goal-snapshot.v1\0"

  def admit(descriptor) when is_map(descriptor) do
    with true <- Enum.sort(Map.keys(descriptor)) == Enum.sort(@fields),
         true <- Enum.all?(@scope_fields, &PrivateMemory.scalar?(descriptor[Atom.to_string(&1)])),
         true <- descriptor["namespace"] == "private_goals",
         {:ok, pair} <- pair_key(descriptor["agent_id"], descriptor["human_id"]),
         true <- descriptor["key"] == pair,
         true <- descriptor["id"] == "memory:private_goals:" <> pair,
         true <- digest?(descriptor["body_digest"]),
         true <- positive_fence?(descriptor["snapshot_revision"]) do
      :ok
    else
      _ -> {:error, :invalid_private_goal_snapshot}
    end
  end

  def admit(_), do: {:error, :invalid_private_goal_snapshot}

  def scope_matches?(descriptor, scope) do
    Enum.all?(@scope_fields, fn key ->
      Map.get(descriptor, Atom.to_string(key)) == Map.get(scope, key)
    end)
  end

  def sign(descriptor, identity) do
    with :ok <- admit(descriptor), {:ok, digest} <- digest(descriptor) do
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

  def verify(descriptor, stamp, identity) when is_map(stamp) do
    with :ok <- admit(descriptor),
         true <- Enum.sort(Map.keys(stamp)) == Enum.sort(@stamp_fields),
         true <- stamp["version"] === 1 and stamp["issuer_id"] == identity.agent_id,
         {:ok, digest} <- digest(descriptor),
         true <- stamp["descriptor_digest"] == digest,
         signature when is_binary(signature) and byte_size(signature) == 88 <- stamp["signature"],
         {:ok, bytes} when byte_size(bytes) == 64 <- Base.decode64(signature),
         true <- Base.encode64(bytes) == signature,
         true <- Crypto.verify(payload(identity.agent_id, digest), bytes, identity.public_key) do
      :ok
    else
      _ -> {:error, :invalid_private_goal_snapshot}
    end
  rescue
    _ -> {:error, :invalid_private_goal_snapshot}
  end

  def verify(_, _, _), do: {:error, :invalid_private_goal_snapshot}

  defp pair_key(agent, human), do: digest([agent, human])

  defp digest(value) do
    with {:ok, bytes} <- TaintEnvelope.canonical_json(value),
         do: {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  end

  defp payload(issuer, digest), do: @domain <> issuer <> "\0" <> digest

  defp positive_fence?(value),
    do: is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807

  defp digest?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp digest?(_), do: false
end
