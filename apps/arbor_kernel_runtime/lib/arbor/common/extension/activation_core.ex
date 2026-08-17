defmodule Arbor.Common.Extension.ActivationCore do
  @moduledoc false

  # Pure activation transaction machine. No Process, IO, crypto, or
  # Application access. The shell validates envelopes, verifies the
  # Platform signature, and interprets nonce effects.

  @type status :: :empty | :staged | :authorized | :committed | :rolled_back | :quarantined

  @type state :: %{
          status: status(),
          transaction: map() | nil,
          transaction_digest: String.t() | nil,
          authorization: map() | nil,
          receipt: map() | nil
        }

  @type bindings :: %{
          required(:transaction_digest) => String.t(),
          required(:signature_status) => :verified | :absent | :forged,
          required(:now) => String.t(),
          required(:consumed_nonces) => MapSet.t(),
          required(:boot_profile_digest) => String.t(),
          required(:boot_epoch) => pos_integer(),
          required(:revoked?) => boolean(),
          required(:allow_commit?) => boolean()
        }

  @spec new() :: state()
  def new do
    %{
      status: :empty,
      transaction: nil,
      transaction_digest: nil,
      authorization: nil,
      receipt: nil
    }
  end

  @spec stage(state(), map(), String.t(), String.t()) :: {:ok, state()} | {:error, String.t()}
  def stage(%{status: :empty}, transaction, now, digest)
      when is_map(transaction) and is_binary(now) and is_binary(digest) do
    if transaction["deadline"] < now do
      {:error, "not_ready"}
    else
      {:ok,
       %{
         status: :staged,
         transaction: transaction,
         transaction_digest: digest,
         authorization: nil,
         receipt: nil
       }}
    end
  end

  def stage(%{status: status}, _transaction, _now, _digest) when status != :empty do
    {:error, "commit_conflict"}
  end

  def stage(_state, _transaction, _now, _digest), do: {:error, "malformed"}

  @spec authorize(state(), map(), bindings()) ::
          {:ok, state(), [term()]} | {:error, String.t()}
  def authorize(%{status: :staged, transaction: transaction} = state, authorization, bindings)
      when is_map(authorization) and is_map(bindings) do
    cond do
      bindings.signature_status == :forged ->
        {:error, "authorization_invalid"}

      bindings.signature_status == :absent ->
        {:error, "authorization_absent"}

      bindings.revoked? ->
        {:error, "authorization_revoked"}

      MapSet.member?(bindings.consumed_nonces, authorization["nonce"]) ->
        {:error, "authorization_replayed"}

      authorization["expires_at"] < bindings.now ->
        {:error, "authorization_expired"}

      authorization["transaction_sha256"] != bindings.transaction_digest ->
        {:error, "transaction_mismatch"}

      authorization["boot_profile_sha256"] != bindings.boot_profile_digest ->
        {:error, "boot_mismatch"}

      authorization["boot_epoch"] != bindings.boot_epoch ->
        {:error, "generation_mismatch"}

      transaction["boot_profile_sha256"] != bindings.boot_profile_digest ->
        {:error, "boot_mismatch"}

      true ->
        {:ok, %{state | status: :authorized, authorization: authorization},
         [{:consume_nonce, authorization["nonce"]}]}
    end
  end

  def authorize(%{status: status}, _authorization, _bindings)
      when status in [:committed, :rolled_back, :quarantined] do
    {:error, "commit_conflict"}
  end

  def authorize(_state, _authorization, _bindings), do: {:error, "not_ready"}

  @spec commit(state(), bindings()) :: {:ok, state()} | {:error, String.t()}
  def commit(%{status: :authorized, transaction: transaction} = state, bindings)
      when is_map(bindings) do
    if bindings.allow_commit? do
      {:ok,
       %{
         state
         | status: :committed,
           receipt: receipt(transaction, state.transaction_digest, "committed", "applied")
       }}
    else
      {:error, "not_ready"}
    end
  end

  def commit(%{status: status}, _bindings)
      when status in [:committed, :rolled_back, :quarantined] do
    {:error, "commit_conflict"}
  end

  def commit(_state, _bindings), do: {:error, "not_ready"}

  @spec rollback(state()) :: {:ok, state()} | {:error, String.t()}
  def rollback(%{status: status, transaction: transaction} = state)
      when status in [:staged, :authorized] and is_map(transaction) do
    {:ok,
     %{
       state
       | status: :rolled_back,
         receipt: receipt(transaction, state.transaction_digest, "rolled_back", "rolled_back")
     }}
  end

  def rollback(%{status: :empty}), do: {:error, "not_ready"}

  def rollback(_state), do: {:error, "commit_conflict"}

  defp receipt(transaction, intent, state, effect_state) do
    %{
      "schema" => "arbor.extension.activation_receipt.v1",
      "version" => 1,
      "transaction_id" => transaction["transaction_id"],
      "transaction_sha256" => intent,
      "artifact_sha256" => transaction["artifact_sha256"],
      "principal_id" => transaction["principal_id"],
      "generation" => transaction["generation"],
      "effects" =>
        Enum.map(transaction["staged_effects"], fn effect ->
          %{
            "id" => effect["id"],
            "class" => effect["class"],
            "state" => effect_state
          }
        end),
      "state" => state,
      "intent_sha256" => intent,
      "cleanup_disposition" => if(state == "rolled_back", do: "pending", else: "none")
    }
  end
end
