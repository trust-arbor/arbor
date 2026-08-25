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
  alias Arbor.Contracts.Security.Identity

  @bound_opt_keys [:now, :consumed_nonces, :revoked]
  @sha256_re ~r/\A[0-9a-f]{64}\z/
  @time_re ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

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

  @doc false
  @spec authorize_bound(ActivationCore.state(), term(), map(), keyword()) ::
          {:ok, ActivationCore.state(), [term()]} | {:error, String.t()}
  def authorize_bound(state, document, snapshot, opts \\ [])

  def authorize_bound(state, document, snapshot, opts)
      when is_map(state) and is_list(opts) do
    with :ok <- admit_bound_opts(opts),
         {:ok, public_key, principal_id, key_id} <- derive_platform_identity(snapshot),
         {:ok, envelope, authorization} <- admit_signed_platform(document),
         :ok <- match_wrapper_identity(envelope, authorization, principal_id, key_id),
         :ok <- match_boot_bindings(authorization, snapshot, state),
         {:ok, current_digest} <- current_transaction_digest(state),
         true <- current_digest == authorization["transaction_sha256"],
         :ok <- verify_platform_signature(envelope, public_key) do
      ActivationCore.authorize(state, authorization, %{
        transaction_digest: current_digest,
        signature_status: :verified,
        now: now(opts),
        consumed_nonces: consumed_nonces(opts),
        boot_profile_digest: snapshot["manifest_sha256"],
        boot_epoch: snapshot["boot_epoch"],
        revoked?: Keyword.get(opts, :revoked, false) == true,
        allow_commit?: false
      })
    else
      false -> {:error, "transaction_mismatch"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _reason} -> {:error, "malformed"}
    end
  end

  def authorize_bound(_state, _document, _snapshot, _opts), do: {:error, "malformed"}

  defp admit_bound_opts(opts) do
    keys = Keyword.keys(opts)

    cond do
      not Keyword.keyword?(opts) ->
        {:error, "malformed"}

      Enum.any?(keys, &(not is_atom(&1))) ->
        {:error, "malformed"}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, "malformed"}

      Enum.any?(keys, &(&1 not in @bound_opt_keys)) ->
        {:error, "malformed"}

      true ->
        admit_bound_opt_values(opts)
    end
  end

  defp admit_bound_opt_values(opts) do
    with :ok <- admit_bound_now(opts),
         :ok <- admit_bound_consumed_nonces(opts),
         :ok <- admit_bound_revoked(opts) do
      :ok
    end
  end

  defp admit_bound_now(opts) do
    case Keyword.fetch(opts, :now) do
      :error ->
        :ok

      {:ok, now} ->
        if canonical_utc_second?(now) do
          :ok
        else
          {:error, "malformed"}
        end
    end
  end

  defp admit_bound_consumed_nonces(opts) do
    case Keyword.fetch(opts, :consumed_nonces) do
      :error -> :ok
      {:ok, %MapSet{}} -> :ok
      {:ok, _} -> {:error, "malformed"}
    end
  end

  defp admit_bound_revoked(opts) do
    case Keyword.fetch(opts, :revoked) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _} -> {:error, "malformed"}
    end
  end

  defp canonical_utc_second?(value) when is_binary(value) do
    String.valid?(value) and Regex.match?(@time_re, value) and canonical_parsed_utc_second?(value)
  end

  defp canonical_utc_second?(_value), do: false

  defp canonical_parsed_utc_second?(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = datetime, 0} ->
        datetime.calendar == Calendar.ISO and datetime.time_zone in ["Etc/UTC", "UTC"] and
          datetime.utc_offset == 0 and datetime.std_offset == 0 and
          datetime.microsecond == {0, 0} and DateTime.to_iso8601(datetime) == value

      _ ->
        false
    end
  end

  defp derive_platform_identity(snapshot) when is_map(snapshot) and not is_struct(snapshot) do
    with {:ok, public_key} <- decode_platform_key(snapshot["platform_public_key"]),
         key_id = lowercase_sha256(public_key),
         true <- key_id == snapshot["platform_key_id"],
         principal_id = Identity.derive_agent_id(public_key) do
      {:ok, public_key, principal_id, key_id}
    else
      false -> {:error, "authorization_invalid"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "boot_mismatch"}
    end
  end

  defp derive_platform_identity(_snapshot), do: {:error, "boot_mismatch"}

  defp decode_platform_key(hex) when is_binary(hex) do
    if String.valid?(hex) and Regex.match?(@sha256_re, hex) do
      case Base.decode16(hex, case: :lower) do
        {:ok, bytes} when byte_size(bytes) == 32 -> {:ok, bytes}
        _ -> {:error, "authorization_invalid"}
      end
    else
      {:error, "authorization_invalid"}
    end
  end

  defp decode_platform_key(_hex), do: {:error, "authorization_invalid"}

  defp admit_signed_platform(%{"schema" => "arbor.extension.signed_envelope.v1"} = document) do
    with {:ok, envelope} <- Envelope.validate_signed(document),
         {:ok, :activation_authorization} <- Envelope.kind_from_domain(envelope["domain"]),
         {:ok, authorization} <-
           Envelope.validate(:activation_authorization, envelope["payload"]) do
      {:ok, envelope, authorization}
    else
      :error -> {:error, "malformed"}
      {:ok, _other} -> {:error, "authorization_invalid"}
      {:error, :digest_mismatch} -> {:error, "authorization_invalid"}
      {:error, :signature_mismatch} -> {:error, "authorization_invalid"}
      {:error, _reason} -> {:error, "malformed"}
    end
  end

  defp admit_signed_platform(document) when is_map(document) do
    case Envelope.validate(:activation_authorization, document) do
      {:ok, _authorization} -> {:error, "authorization_absent"}
      {:error, _reason} -> {:error, "malformed"}
    end
  end

  defp admit_signed_platform(_document), do: {:error, "malformed"}

  defp match_wrapper_identity(envelope, authorization, principal_id, key_id) do
    cond do
      envelope["issuer_id"] != principal_id or authorization["issuer_id"] != principal_id ->
        {:error, "principal_denied"}

      envelope["key_id"] != key_id or authorization["key_id"] != key_id ->
        {:error, "authorization_invalid"}

      true ->
        :ok
    end
  end

  defp match_boot_bindings(authorization, snapshot, %{transaction: transaction})
       when is_map(transaction) do
    cond do
      authorization["boot_profile_sha256"] != snapshot["manifest_sha256"] ->
        {:error, "boot_mismatch"}

      transaction["boot_profile_sha256"] != snapshot["manifest_sha256"] ->
        {:error, "boot_mismatch"}

      transaction["boot_profile_id"] != snapshot["profile_id"] ->
        {:error, "boot_mismatch"}

      authorization["boot_epoch"] != snapshot["boot_epoch"] ->
        {:error, "generation_mismatch"}

      true ->
        :ok
    end
  end

  defp match_boot_bindings(_authorization, _snapshot, _state), do: {:error, "not_ready"}

  defp current_transaction_digest(%{transaction: transaction, transaction_digest: stored})
       when is_map(transaction) and is_binary(stored) do
    case Envelope.digest_of(transaction) do
      {:ok, ^stored} -> {:ok, stored}
      {:ok, _other} -> {:error, "transaction_mismatch"}
      {:error, _reason} -> {:error, "malformed"}
    end
  end

  defp current_transaction_digest(_state), do: {:error, "not_ready"}

  defp verify_platform_signature(envelope, public_key) do
    case verify_signature(envelope, public_key) do
      :verified -> :ok
      _ -> {:error, "authorization_invalid"}
    end
  end

  defp lowercase_sha256(bytes) do
    Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

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
