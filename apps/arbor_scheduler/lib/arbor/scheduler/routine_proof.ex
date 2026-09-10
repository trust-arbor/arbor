defmodule Arbor.Scheduler.RoutineProof do
  @moduledoc false

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Scheduler.Cores.RoutineCore
  alias Arbor.Security

  @legacy_keys ~w(payload agent_id timestamp nonce signature)
  @wire_keys ~w(version payload_base64 agent_id timestamp nonce signature)
  @payload_limit 65_536
  @encoded_payload_limit 87_384

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
      "version" => 2,
      "payload_base64" => Base.encode64(proof.payload),
      "agent_id" => proof.agent_id,
      "timestamp" => DateTime.to_iso8601(proof.timestamp),
      "nonce" => Base.encode64(proof.nonce),
      "signature" => Base.encode64(proof.signature)
    }
  end

  # The domain-separated payload contains NUL bytes. PostgreSQL jsonb cannot
  # store those bytes as JSON text; encode the wire without changing the signed
  # request. Legacy SQLite rows remain readable, but new writes are always v2.
  def decode(%{"version" => 2} = wire) when map_size(wire) == 6 do
    with true <- Enum.sort(Map.keys(wire)) == Enum.sort(@wire_keys),
         true <- bounded?(wire["payload_base64"], @encoded_payload_limit),
         {:ok, payload} <- canonical_base64(wire["payload_base64"]),
         true <- bounded?(payload, @payload_limit) do
      decode_fields(wire, payload)
    else
      _ -> {:error, :invalid_routine_proof}
    end
  end

  def decode(wire) when is_map(wire) and map_size(wire) == 5 do
    with true <- Enum.sort(Map.keys(wire)) == Enum.sort(@legacy_keys),
         true <- bounded?(wire["payload"], @payload_limit) do
      decode_fields(wire, wire["payload"])
    else
      _ -> {:error, :invalid_routine_proof}
    end
  end

  def decode(_), do: {:error, :invalid_routine_proof}

  defp decode_fields(wire, payload) do
    with true <- bounded?(wire["agent_id"], 256),
         true <- bounded?(wire["timestamp"], 40),
         true <- bounded?(wire["nonce"], 64),
         true <- bounded?(wire["signature"], 128),
         {:ok, timestamp, 0} <- DateTime.from_iso8601(wire["timestamp"]),
         {:ok, nonce} <- canonical_base64(wire["nonce"]),
         {:ok, signature} <- canonical_base64(wire["signature"]) do
      SignedRequest.new(
        payload: payload,
        agent_id: wire["agent_id"],
        timestamp: timestamp,
        nonce: nonce,
        signature: signature
      )
    else
      _ -> {:error, :invalid_routine_proof}
    end
  end

  defp canonical_base64(encoded) do
    with {:ok, decoded} <- Base.decode64(encoded),
         true <- Base.encode64(decoded) == encoded do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_routine_proof}
    end
  end

  defp bounded?(value, limit),
    do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)
end
