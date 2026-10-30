defmodule Arbor.Security.Extension.PlatformActivationAuthorizationCore do
  @moduledoc false

  # Pure construction of a Platform activation authorization envelope.
  # No Process, IO, Application, File, ETS, GenServer, or private-key use.

  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.Contracts.Security.Identity

  @snapshot_schema "arbor.kernel_runtime.boot_profile_binding.v1"
  @context_keys [
    :audience_host_id,
    :audience_install_id,
    :issued_at,
    :expires_at,
    :nonce
  ]
  @forbidden_keys MapSet.new([
                    :issuer_id,
                    :key_id,
                    :boot_epoch,
                    :boot_profile_sha256,
                    :boot_profile_id,
                    :platform_public_key,
                    :platform_key_id,
                    :profile_id,
                    :transaction_sha256,
                    :signature,
                    :public_key,
                    :private_key,
                    :signer,
                    :authority,
                    :principal_id,
                    :payload,
                    :schema,
                    :version
                  ])
  @required_snapshot_keys [
    "schema",
    "version",
    "manifest_sha256",
    "profile_id",
    "boot_epoch",
    "platform_public_key",
    "platform_key_id",
    "valid_from",
    "valid_until"
  ]
  @sha256_re ~r/\A[0-9a-f]{64}\z/
  @nonce_re ~r/\A[0-9a-f]{32}\z/
  @id_re ~r/\A[a-z0-9][a-z0-9._:-]{0,127}\z/
  @time_re ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
  @max_epoch 1_000_000_000
  @max_id_bytes 128
  @placeholder_signature String.duplicate("00", 64)

  @type t :: %{
          payload: map(),
          unsigned_envelope: map(),
          signing_message: binary(),
          platform_public_key: binary(),
          principal_id: String.t(),
          key_id: String.t()
        }

  @spec build(map()) :: {:ok, t()} | {:error, atom()}
  def build(input) when is_map(input) and not is_struct(input) do
    with {:ok, snapshot} <- fetch(input, :snapshot),
         {:ok, transaction} <- fetch(input, :transaction),
         {:ok, digest} <- fetch(input, :digest),
         {:ok, context} <- fetch(input, :context),
         {:ok, principal_id} <- fetch(input, :authority_principal_id),
         {:ok, purpose} <- fetch(input, :authority_purpose),
         {:ok, snapshot} <- admit_snapshot(snapshot),
         {:ok, public_key, key_id, derived_principal} <- derive_platform_identity(snapshot),
         :ok <- match_purpose(purpose),
         :ok <- match_principal(principal_id, derived_principal),
         {:ok, context} <- admit_context(context),
         :ok <- match_transaction_boot(transaction, snapshot),
         :ok <- match_digest(transaction, digest),
         :ok <- match_validity_window(context, snapshot),
         {:ok, payload} <- build_payload(snapshot, derived_principal, key_id, digest, context),
         {:ok, unsigned, message} <- build_unsigned(payload, derived_principal, key_id) do
      {:ok,
       %{
         payload: payload,
         unsigned_envelope: unsigned,
         signing_message: message,
         platform_public_key: public_key,
         principal_id: derived_principal,
         key_id: key_id
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      :error -> {:error, :invalid_context}
    end
  end

  def build(_input), do: {:error, :invalid_context}

  @spec attach_signature(t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def attach_signature(
        %{unsigned_envelope: unsigned} = built,
        signature_hex
      )
      when is_map(built) and is_binary(signature_hex) do
    with :ok <- signature_hex(signature_hex) do
      envelope = Map.put(unsigned, "signature", signature_hex)

      case Envelope.validate_signed(envelope) do
        {:ok, validated} -> {:ok, validated}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :invalid_envelope}
      end
    end
  end

  def attach_signature(_built, _signature_hex), do: {:error, :invalid_signature}

  defp fetch(input, key) do
    case Map.fetch(input, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_context}
    end
  end

  defp admit_snapshot(snapshot) when is_map(snapshot) and not is_struct(snapshot) do
    keys = Map.keys(snapshot)

    cond do
      Enum.any?(keys, &is_atom/1) and Enum.any?(keys, &is_binary/1) ->
        {:error, :mixed_option_keys}

      Enum.any?(keys, &(not is_binary(&1))) ->
        {:error, :invalid_boot_profile}

      Enum.any?(@required_snapshot_keys, &(&1 not in keys)) ->
        {:error, :invalid_boot_profile}

      snapshot["schema"] != @snapshot_schema ->
        {:error, :invalid_boot_profile}

      snapshot["version"] != 1 ->
        {:error, :invalid_boot_profile}

      not digest?(snapshot["manifest_sha256"]) ->
        {:error, :invalid_boot_profile}

      not id?(snapshot["profile_id"]) ->
        {:error, :invalid_boot_profile}

      not epoch?(snapshot["boot_epoch"]) ->
        {:error, :invalid_boot_profile}

      not timestamp?(snapshot["valid_from"]) ->
        {:error, :invalid_boot_profile}

      not timestamp?(snapshot["valid_until"]) ->
        {:error, :invalid_boot_profile}

      snapshot["valid_from"] > snapshot["valid_until"] ->
        {:error, :invalid_boot_profile}

      true ->
        {:ok, snapshot}
    end
  end

  defp admit_snapshot(_snapshot), do: {:error, :invalid_boot_profile}

  defp derive_platform_identity(snapshot) do
    with {:ok, public_key} <- decode_platform_key(snapshot["platform_public_key"]),
         key_id = lowercase_sha256(public_key),
         true <- key_id == snapshot["platform_key_id"] do
      {:ok, public_key, key_id, Identity.derive_agent_id(public_key)}
    else
      false -> {:error, :platform_key_id_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_platform_key(hex) when is_binary(hex) do
    if String.valid?(hex) and Regex.match?(@sha256_re, hex) do
      case Base.decode16(hex, case: :lower) do
        {:ok, bytes} when byte_size(bytes) == 32 -> {:ok, bytes}
        _ -> {:error, :invalid_public_key}
      end
    else
      {:error, :invalid_public_key}
    end
  end

  defp decode_platform_key(_hex), do: {:error, :invalid_public_key}

  defp match_purpose(:platform_activation), do: :ok
  defp match_purpose(_purpose), do: {:error, :purpose_mismatch}

  defp match_principal(principal_id, principal_id) when is_binary(principal_id), do: :ok
  defp match_principal(_principal_id, _expected), do: {:error, :principal_mismatch}

  defp admit_context(context) when is_map(context) and not is_struct(context) do
    keys = Map.keys(context)

    cond do
      Enum.any?(keys, &(not is_atom(&1))) ->
        {:error, :mixed_option_keys}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, :duplicate_attribute}

      Enum.any?(keys, &MapSet.member?(@forbidden_keys, &1)) ->
        {:error, :forbidden_attribute}

      Enum.any?(keys, &(&1 not in @context_keys)) ->
        {:error, :unknown_attribute}

      Enum.sort(keys) != Enum.sort(@context_keys) ->
        {:error, :invalid_context}

      not id?(context.audience_host_id) ->
        {:error, :invalid_id}

      not id?(context.audience_install_id) ->
        {:error, :invalid_id}

      not timestamp?(context.issued_at) ->
        {:error, :invalid_timestamp}

      not timestamp?(context.expires_at) ->
        {:error, :invalid_timestamp}

      not nonce?(context.nonce) ->
        {:error, :invalid_nonce}

      true ->
        {:ok, context}
    end
  end

  defp admit_context(_context), do: {:error, :invalid_context}

  defp match_transaction_boot(transaction, snapshot) when is_map(transaction) do
    cond do
      transaction["boot_profile_sha256"] != snapshot["manifest_sha256"] ->
        {:error, :boot_mismatch}

      transaction["boot_profile_id"] != snapshot["profile_id"] ->
        {:error, :boot_mismatch}

      true ->
        :ok
    end
  end

  defp match_transaction_boot(_transaction, _snapshot), do: {:error, :invalid_transaction}

  defp match_digest(transaction, digest) when is_binary(digest) do
    case Envelope.digest_of(transaction) do
      {:ok, ^digest} -> :ok
      {:ok, _other} -> {:error, :invalid_transaction}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_transaction}
    end
  end

  defp match_digest(_transaction, _digest), do: {:error, :invalid_transaction}

  defp match_validity_window(context, snapshot) do
    issued_at = context.issued_at
    expires_at = context.expires_at

    cond do
      issued_at > expires_at ->
        {:error, :invalid_validity_window}

      issued_at < snapshot["valid_from"] ->
        {:error, :invalid_validity_window}

      expires_at > snapshot["valid_until"] ->
        {:error, :invalid_validity_window}

      true ->
        :ok
    end
  end

  defp build_payload(snapshot, principal_id, key_id, digest, context) do
    payload = %{
      "schema" => Envelope.schema(:activation_authorization),
      "version" => 1,
      "transaction_sha256" => digest,
      "issuer_id" => principal_id,
      "key_id" => key_id,
      "audience_host_id" => context.audience_host_id,
      "audience_install_id" => context.audience_install_id,
      "boot_epoch" => snapshot["boot_epoch"],
      "boot_profile_sha256" => snapshot["manifest_sha256"],
      "issued_at" => context.issued_at,
      "expires_at" => context.expires_at,
      "nonce" => context.nonce
    }

    case Envelope.validate(:activation_authorization, payload) do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_envelope}
    end
  end

  defp build_unsigned(payload, principal_id, key_id) do
    with {:ok, payload_sha256} <- Envelope.digest_of(payload) do
      unsigned = %{
        "schema" => Envelope.signed_schema(),
        "version" => 1,
        "domain" => Envelope.schema(:activation_authorization),
        "payload_encoding" => "canonical_json_v1",
        "payload_sha256" => payload_sha256,
        "issuer_id" => principal_id,
        "key_id" => key_id,
        "signature" => @placeholder_signature,
        "payload" => payload
      }

      case Envelope.signing_message(unsigned) do
        {:ok, message} -> {:ok, unsigned, message}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :invalid_envelope}
      end
    end
  end

  defp lowercase_sha256(bytes) do
    Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  defp digest?(value) when is_binary(value),
    do: String.valid?(value) and Regex.match?(@sha256_re, value)

  defp digest?(_value), do: false

  defp nonce?(value) when is_binary(value),
    do: String.valid?(value) and Regex.match?(@nonce_re, value)

  defp nonce?(_value), do: false

  defp timestamp?(value) when is_binary(value),
    do: String.valid?(value) and Regex.match?(@time_re, value)

  defp timestamp?(_value), do: false

  defp id?(value) when is_binary(value) do
    String.valid?(value) and byte_size(value) <= @max_id_bytes and Regex.match?(@id_re, value)
  end

  defp id?(_value), do: false

  defp epoch?(value) when is_integer(value) and value >= 1 and value <= @max_epoch, do: true
  defp epoch?(_value), do: false

  defp signature_hex(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(~r/\A[0-9a-f]{128}\z/, value) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp signature_hex(_value), do: {:error, :invalid_signature}
end
