defmodule Arbor.Common.ExtensionEnvelopes do
  @moduledoc """
  Kernel-runtime consumer of the E0C provider and invocation envelopes.

  Registries and local fake transports admit only these closed maps.
  Handles never carry a public module atom or raw PID.
  """

  alias Arbor.Contracts.Extension.Envelope

  @runtime_kinds [
    :provider_handle,
    :activation_transaction,
    :activation_receipt,
    :invocation_request,
    :invocation_result
  ]

  @doc "Validates a runtime-owned E0C envelope."
  @spec validate(atom(), term()) :: {:ok, map()} | {:error, atom()}
  def validate(kind, document) when kind in @runtime_kinds do
    with {:ok, document} <- Envelope.validate(kind, document),
         :ok <- reject_executable_identity(kind, document) do
      {:ok, document}
    end
  end

  def validate(_kind, _document), do: {:error, :unsupported_kind}

  @doc "Validates a signed runtime envelope."
  @spec validate_signed(term()) :: {:ok, map()} | {:error, atom()}
  def validate_signed(document) do
    with {:ok, envelope} <- Envelope.validate_signed(document),
         {:ok, kind} <- signed_kind(envelope),
         true <- kind in @runtime_kinds,
         :ok <- reject_executable_identity(kind, envelope["payload"]) do
      {:ok, envelope}
    else
      false -> {:error, :unsupported_kind}
      {:error, reason} -> {:error, reason}
    end
  end

  defp signed_kind(%{"domain" => domain}) do
    Envelope.kinds()
    |> Enum.find_value({:error, :unknown_kind}, fn kind ->
      if Envelope.schema(kind) == domain, do: {:ok, kind}
    end)
  end

  defp reject_executable_identity(:provider_handle, document) do
    forbidden = ["module", "pid", "node", "mfa"]

    if Enum.any?(forbidden, &Map.has_key?(document, &1)) do
      {:error, :executable_identity}
    else
      :ok
    end
  end

  defp reject_executable_identity(_kind, _document), do: :ok
end
