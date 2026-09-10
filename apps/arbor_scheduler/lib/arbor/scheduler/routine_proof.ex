defmodule Arbor.Scheduler.RoutineProof do
  @moduledoc false

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Scheduler.Cores.RoutineCore
  alias Arbor.Security

  @keys ~w(payload agent_id timestamp nonce signature)

  def fresh(operation, value, proof) do
    with {:ok, expected} <- RoutineCore.payload(operation, value),
         {:ok, proof} <- SignedRequest.canonicalize(proof),
         true <- proof.payload == expected,
         {:ok, principal} <- Security.verify_request(proof),
         {:ok, :active} <- Security.identity_status(principal) do
      {:ok, principal, encode(proof)}
    else
      _ -> {:error, :routine_authentication_failed}
    end
  end

  # A queued intent is historical evidence, not a fresh external request.
  # Nonce/freshness were consumed at enqueue. Current identity and authority
  # remain separate checks on every subsequent use.
  def historical(intent, wire) do
    with {:ok, expected} <- RoutineCore.payload(:enqueue, intent),
         {:ok, proof} <- decode(wire),
         true <- proof.payload == expected,
         {:ok, :active} <- Security.identity_status(proof.agent_id),
         {:ok, key} <- Security.lookup_public_key(proof.agent_id),
         :ok <-
           Security.verify_detached(SignedRequest.signing_payload(proof), proof.signature, key) do
      {:ok, proof.agent_id}
    else
      _ -> {:error, :routine_authentication_failed}
    end
  end

  def encode(proof) do
    %{
      "payload" => proof.payload,
      "agent_id" => proof.agent_id,
      "timestamp" => DateTime.to_iso8601(proof.timestamp),
      "nonce" => Base.encode64(proof.nonce),
      "signature" => Base.encode64(proof.signature)
    }
  end

  def decode(wire) when is_map(wire) and map_size(wire) == 5 do
    with true <- Enum.sort(Map.keys(wire)) == Enum.sort(@keys),
         true <- bounded?(wire["payload"], 65_536),
         true <- bounded?(wire["agent_id"], 256),
         true <- bounded?(wire["timestamp"], 40),
         true <- bounded?(wire["nonce"], 64),
         true <- bounded?(wire["signature"], 128),
         {:ok, timestamp, 0} <- DateTime.from_iso8601(wire["timestamp"]),
         {:ok, nonce} <- Base.decode64(wire["nonce"]),
         {:ok, signature} <- Base.decode64(wire["signature"]) do
      SignedRequest.new(
        payload: wire["payload"],
        agent_id: wire["agent_id"],
        timestamp: timestamp,
        nonce: nonce,
        signature: signature
      )
    else
      _ -> {:error, :invalid_routine_proof}
    end
  end

  def decode(_), do: {:error, :invalid_routine_proof}

  defp bounded?(value, limit),
    do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)
end
