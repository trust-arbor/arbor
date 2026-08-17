defmodule Arbor.Common.Extension.FakeTransport do
  @moduledoc """
  Local and external fake providers for E0C invocation conformance.

  Both classes consume the same closed request fixture. They never accept
  open `term()` input or return a provider exception. Transport loss is
  an unknown effect disposition and blocks retry unless the protocol is
  marked idempotent.
  """

  alias Arbor.Common.Extension.InvocationCore
  alias Arbor.Common.ExtensionEnvelopes
  alias Arbor.Contracts.Extension.Envelope

  @classes MapSet.new(["external", "local_module"])

  @doc "Invoke one fake provider with closed handle, authorization, and request."
  @spec invoke(String.t(), map(), keyword()) ::
          {:ok, map(), [term()]} | {:pending, map(), [term()]} | {:error, String.t()}
  def invoke(class, input, opts \\ [])

  def invoke(class, input, opts) when is_binary(class) and is_map(input) and is_list(opts) do
    with true <- MapSet.member?(@classes, class),
         {:ok, handle} <- fetch_handle(input),
         true <- handle["transport_class"] == class,
         {:ok, authorization, signature_status} <- admit_authorization(input, opts),
         {:ok, request} <- fetch_request(input),
         {:ok, effects} <-
           InvocationCore.admit(handle, authorization, request, %{
             now: now(opts),
             request_digest: request["request_sha256"],
             signature_status: admit_signature(signature_status, opts),
             consumed_nonces: consumed_nonces(opts),
             revoked?: Keyword.get(opts, :revoked, false) == true,
             pending_unknown?: Keyword.get(opts, :pending_unknown, false) == true,
             idempotent?: Keyword.get(opts, :idempotent, false) == true
           }) do
      finish(class, request, effects, opts)
    else
      false -> {:error, "malformed"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _reason} -> {:error, "malformed"}
    end
  end

  def invoke(_class, _input, _opts), do: {:error, "malformed"}

  defp fetch_handle(%{"handle" => handle}),
    do: ExtensionEnvelopes.validate(:provider_handle, handle)

  defp fetch_handle(%{handle: handle}), do: ExtensionEnvelopes.validate(:provider_handle, handle)
  defp fetch_handle(_input), do: {:error, "malformed"}

  defp fetch_request(%{"request" => request}),
    do: ExtensionEnvelopes.validate(:invocation_request, request)

  defp fetch_request(%{request: request}),
    do: ExtensionEnvelopes.validate(:invocation_request, request)

  defp fetch_request(_input), do: {:error, "malformed"}

  defp admit_authorization(input, opts) do
    document = Map.get(input, "authorization") || Map.get(input, :authorization)
    admit_authorization_document(document, opts)
  end

  defp admit_authorization_document(
         %{"schema" => "arbor.extension.signed_envelope.v1"} = document,
         opts
       ) do
    with {:ok, envelope} <- Envelope.validate_signed(document),
         {:ok, :invocation_authorization} <- Envelope.kind_from_domain(envelope["domain"]),
         {:ok, authorization} <-
           Envelope.validate(:invocation_authorization, envelope["payload"]) do
      {:ok, authorization, signature_status(envelope, opts)}
    else
      :error -> {:error, "malformed"}
      {:ok, _other} -> {:error, "denied"}
      {:error, _reason} -> {:error, "malformed"}
    end
  end

  defp admit_authorization_document(document, _opts) when is_map(document) do
    case Envelope.validate(:invocation_authorization, document) do
      {:ok, authorization} -> {:ok, authorization, :absent}
      {:error, _reason} -> {:error, "malformed"}
    end
  end

  defp admit_authorization_document(_document, _opts), do: {:error, "malformed"}

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

  defp admit_signature(:absent, opts) do
    if Keyword.get(opts, :allow_unsigned, false) == true, do: :verified, else: :absent
  end

  defp admit_signature(status, _opts), do: status

  defp finish("external", request, effects, opts) do
    if Keyword.get(opts, :loss, false) == true do
      with {:ok, result} <- result_envelope(request, "error", "provider_unavailable", "unknown") do
        {:pending, result, effects}
      end
    else
      deliver(request, effects)
    end
  end

  defp finish("local_module", request, effects, _opts), do: deliver(request, effects)

  defp deliver(request, effects) do
    with {:ok, result} <- result_envelope(request, "ok", nil, "applied") do
      {:ok, result, effects}
    end
  end

  defp result_envelope(request, status, error_code, disposition) do
    payload = %{"upserted" => 1}

    with {:ok, payload_sha256} <- Envelope.digest_of(payload),
         result <- %{
           "schema" => Envelope.schema(:invocation_result),
           "version" => 1,
           "protocol_id" => request["protocol_id"],
           "protocol_schema" => request["protocol_schema"],
           "generation" => request["generation"],
           "request_sha256" => request["request_sha256"],
           "payload_sha256" => payload_sha256,
           "status" => status,
           "error_code" => error_code,
           "result_sha256" => payload_sha256,
           "taint_sha256" => String.duplicate("ab", 32),
           "metering" => %{"tokens" => 0, "bytes" => 8, "ms" => 1},
           "effect_disposition" => disposition
         },
         {:ok, result} <- ExtensionEnvelopes.validate(:invocation_result, result) do
      {:ok, result}
    else
      {:error, _reason} -> {:error, "invalid_result"}
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
