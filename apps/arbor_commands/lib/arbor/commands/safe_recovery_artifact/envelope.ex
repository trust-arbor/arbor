defmodule Arbor.Commands.SafeRecoveryArtifact.Envelope do
  @moduledoc """
  Pure closed envelope descriptor for the committed E0B2C3c1
  safe-recovery artifact payload.

  The envelope is a bounded descriptor plus a digest of the committed
  payload file -- never a second unsigned payload. It carries no manifest
  fields; every evidence field lives in the payload file itself.
  """

  alias Arbor.Commands.SafeRecoveryArtifact.Encode

  @schema "arbor.packaging.safe_recovery_artifact.envelope.v1"
  @version 1
  @payload_path "apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json"
  @max_payload_bytes 16_777_216

  @envelope_keys ["schema", "version", "payload"]
  @payload_keys ["schema", "path", "byte_size", "sha256"]

  @digest_re ~r/\A[0-9a-f]{64}\z/

  @doc "Closed envelope schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Closed envelope version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The single committed payload path bound by every envelope."
  @spec payload_path() :: String.t()
  def payload_path, do: @payload_path

  @doc "Build the envelope descriptor from the exact payload file bytes."
  @spec build(binary()) :: {:ok, map()} | {:error, term()}
  def build(payload_bytes) when is_binary(payload_bytes) do
    size = byte_size(payload_bytes)

    if size >= 1 and size <= @max_payload_bytes do
      {:ok,
       %{
         "schema" => @schema,
         "version" => @version,
         "payload" => %{
           "schema" => Encode.schema(),
           "path" => @payload_path,
           "byte_size" => size,
           "sha256" => sha256_hex(payload_bytes)
         }
       }}
    else
      {:error, :invalid_payload_size}
    end
  end

  def build(_payload_bytes), do: {:error, :invalid_payload}

  @doc "Strictly validate the closed envelope descriptor."
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(envelope) when is_map(envelope) and not is_struct(envelope) do
    with :ok <- Encode.validate_closed_map(envelope, @envelope_keys),
         :ok <- require_schema(envelope),
         :ok <- require_version(envelope),
         {:ok, payload} <- admit_payload(envelope) do
      validate_payload(payload)
    end
  end

  def validate(_envelope), do: {:error, :invalid_envelope}

  @doc "Validate then encode the envelope as canonical JSON bytes."
  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(envelope) do
    case validate(envelope) do
      :ok -> Encode.canonical_json(envelope)
      error -> error
    end
  end

  defp require_schema(%{"schema" => @schema}), do: :ok
  defp require_schema(%{"schema" => _other}), do: {:error, :invalid_schema}

  defp require_schema(_envelope), do: {:error, :invalid_schema}

  defp require_version(%{"version" => @version}), do: :ok
  defp require_version(%{"version" => _other}), do: {:error, :invalid_version}

  defp require_version(_envelope), do: {:error, :invalid_version}

  defp admit_payload(%{"payload" => payload}) when is_map(payload) and not is_struct(payload),
    do: {:ok, payload}

  defp admit_payload(_envelope), do: {:error, :invalid_payload}

  defp validate_payload(payload) do
    with :ok <- Encode.validate_closed_map(payload, @payload_keys),
         :ok <- require_payload_schema(payload),
         :ok <- require_payload_path(payload),
         :ok <- require_payload_size(payload) do
      require_payload_digest(payload)
    end
  end

  defp require_payload_schema(%{"schema" => schema}) do
    if schema == Encode.schema(), do: :ok, else: {:error, :invalid_schema}
  end

  defp require_payload_path(%{"path" => path}) do
    if path == @payload_path, do: :ok, else: {:error, :payload_path_mismatch}
  end

  defp require_payload_size(%{"byte_size" => size})
       when is_integer(size) and size >= 1 and size <= @max_payload_bytes,
       do: :ok

  defp require_payload_size(%{"byte_size" => size}) when is_integer(size),
    do: {:error, :invalid_payload_size}

  defp require_payload_size(_payload), do: {:error, :invalid_payload_size}

  defp require_payload_digest(%{"sha256" => digest}) when is_binary(digest) do
    if Regex.match?(@digest_re, digest), do: :ok, else: {:error, :invalid_digest}
  end

  defp require_payload_digest(_payload), do: {:error, :invalid_digest}

  defp sha256_hex(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end
end
