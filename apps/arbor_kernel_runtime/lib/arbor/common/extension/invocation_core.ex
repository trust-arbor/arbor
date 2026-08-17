defmodule Arbor.Common.Extension.InvocationCore do
  @moduledoc false

  # Pure invocation-proxy admission. The shell validates envelopes,
  # verifies signatures, and interprets nonce / pending-unknown effects.

  @type bindings :: %{
          required(:now) => String.t(),
          required(:request_digest) => String.t(),
          required(:signature_status) => :verified | :absent | :forged,
          required(:consumed_nonces) => MapSet.t(),
          required(:revoked?) => boolean(),
          required(:pending_unknown?) => boolean(),
          required(:idempotent?) => boolean()
        }

  @spec admit(map(), map(), map(), bindings()) ::
          {:ok, [term()]} | {:error, String.t()}
  def admit(handle, authorization, request, bindings)
      when is_map(handle) and is_map(authorization) and is_map(request) and is_map(bindings) do
    with :ok <- authority(bindings, authorization),
         :ok <- liveness(handle, authorization, bindings),
         :ok <- identity(handle, authorization, request, bindings) do
      {:ok, [{:consume_nonce, authorization["nonce"]}]}
    end
  end

  def admit(_handle, _authorization, _request, _bindings), do: {:error, "malformed"}

  defp authority(bindings, authorization) do
    cond do
      bindings.signature_status in [:forged, :absent] ->
        {:error, "denied"}

      bindings.revoked? ->
        {:error, "revoked_during_use"}

      MapSet.member?(bindings.consumed_nonces, authorization["nonce"]) ->
        {:error, "replayed"}

      bindings.pending_unknown? and not bindings.idempotent? ->
        {:error, "effect_disposition_unknown"}

      true ->
        :ok
    end
  end

  defp liveness(handle, authorization, bindings) do
    cond do
      handle["lease_expires_at"] < bindings.now -> {:error, "expired"}
      authorization["deadline"] < bindings.now -> {:error, "deadline_exceeded"}
      true -> :ok
    end
  end

  defp identity(handle, authorization, request, bindings) do
    cond do
      authorization["request_sha256"] != bindings.request_digest -> {:error, "digest_mismatch"}
      handle["handle_id"] != authorization["handle_id"] -> {:error, "denied"}
      handle["lease_id"] != authorization["lease_id"] -> {:error, "expired"}
      handle["generation"] != authorization["generation"] -> {:error, "denied"}
      request["generation"] != handle["generation"] -> {:error, "denied"}
      handle["protocol_id"] != authorization["protocol_id"] -> {:error, "malformed"}
      request["protocol_id"] != handle["protocol_id"] -> {:error, "malformed"}
      true -> :ok
    end
  end
end
