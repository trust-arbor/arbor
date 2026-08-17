defmodule Arbor.Common.Extension.Activation do
  @moduledoc """
  Kernel-runtime shell for E0C activation transactions.

  Production commit stays disabled until a later packet supplies a
  boot-profile Platform signing identity. Tests and fake providers pass
  `allow_commit: true` after verifying a signed authorization.
  """

  alias Arbor.Common.Extension.ActivationCore
  alias Arbor.Common.ExtensionEnvelopes
  alias Arbor.Contracts.Extension.Envelope

  @doc "Returns an empty activation machine."
  @spec new() :: ActivationCore.state()
  def new, do: ActivationCore.new()

  @doc "Stage a validated activation transaction."
  @spec stage(ActivationCore.state(), term(), keyword()) ::
          {:ok, ActivationCore.state()} | {:error, String.t()}
  def stage(state, transaction, opts \\ []) when is_map(state) and is_list(opts) do
    with {:ok, transaction} <- ExtensionEnvelopes.validate(:activation_transaction, transaction),
         {:ok, digest} <- Envelope.digest_of(transaction) do
      ActivationCore.stage(state, transaction, now(opts), digest)
    else
      {:error, reason} when is_atom(reason) -> {:error, "malformed"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Authorize a staged transaction with a signed or unsigned authorization."
  @spec authorize(ActivationCore.state(), term(), keyword()) ::
          {:ok, ActivationCore.state(), [term()]} | {:error, String.t()}
  def authorize(state, document, opts \\ []) when is_map(state) and is_list(opts) do
    with {:ok, authorization, signature_status} <- admit_authorization(document, opts) do
      ActivationCore.authorize(state, authorization, %{
        transaction_digest: state.transaction_digest,
        signature_status: signature_status,
        now: now(opts),
        consumed_nonces: consumed_nonces(opts),
        boot_profile_digest: Keyword.get(opts, :boot_profile_digest, ""),
        boot_epoch: Keyword.get(opts, :boot_epoch, 1),
        revoked?: Keyword.get(opts, :revoked, false) == true,
        allow_commit?: Keyword.get(opts, :allow_commit, false) == true
      })
    end
  end

  @doc "Commit an authorized transaction when the caller explicitly allows it."
  @spec commit(ActivationCore.state(), keyword()) ::
          {:ok, ActivationCore.state()} | {:error, String.t()}
  def commit(state, opts \\ []) when is_map(state) and is_list(opts) do
    ActivationCore.commit(state, %{
      transaction_digest: state.transaction_digest,
      signature_status: :verified,
      now: now(opts),
      consumed_nonces: consumed_nonces(opts),
      boot_profile_digest: Keyword.get(opts, :boot_profile_digest, ""),
      boot_epoch: Keyword.get(opts, :boot_epoch, 1),
      revoked?: false,
      allow_commit?: Keyword.get(opts, :allow_commit, false) == true
    })
  end

  @doc "Roll back a staged or authorized transaction."
  @spec rollback(ActivationCore.state()) :: {:ok, ActivationCore.state()} | {:error, String.t()}
  def rollback(state) when is_map(state), do: ActivationCore.rollback(state)

  defp admit_authorization(%{"schema" => "arbor.extension.signed_envelope.v1"} = document, opts) do
    with {:ok, envelope} <- Envelope.validate_signed(document),
         {:ok, :activation_authorization} <- Envelope.kind_from_domain(envelope["domain"]),
         {:ok, authorization} <-
           Envelope.validate(:activation_authorization, envelope["payload"]) do
      {:ok, authorization, signature_status(envelope, opts)}
    else
      :error -> {:error, "malformed"}
      {:ok, _other} -> {:error, "authorization_invalid"}
      {:error, :digest_mismatch} -> {:error, "authorization_invalid"}
      {:error, :signature_mismatch} -> {:error, "authorization_invalid"}
      {:error, reason} when is_atom(reason) -> {:error, "malformed"}
    end
  end

  defp admit_authorization(document, _opts) when is_map(document) do
    case Envelope.validate(:activation_authorization, document) do
      {:ok, authorization} -> {:ok, authorization, :absent}
      {:error, _reason} -> {:error, "malformed"}
    end
  end

  defp admit_authorization(_document, _opts), do: {:error, "malformed"}

  defp signature_status(envelope, opts) do
    case Keyword.get(opts, :public_key) do
      nil ->
        :absent

      public_key when is_binary(public_key) ->
        verify_signature(envelope, public_key)

      _other ->
        :forged
    end
  end

  defp verify_signature(envelope, public_key) do
    with {:ok, message} <- Envelope.signing_message(envelope),
         {:ok, signature} <- decode_signature(envelope["signature"]),
         true <-
           :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519]) do
      :verified
    else
      _ -> :forged
    end
  end

  defp decode_signature(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bytes} when byte_size(bytes) == 64 -> {:ok, bytes}
      _ -> :error
    end
  end

  defp now(opts) do
    case Keyword.get(opts, :now) do
      now when is_binary(now) -> now
      _ -> "1970-01-01T00:00:00Z"
    end
  end

  defp consumed_nonces(opts) do
    case Keyword.get(opts, :consumed_nonces) do
      %MapSet{} = set -> set
      _ -> MapSet.new()
    end
  end
end
