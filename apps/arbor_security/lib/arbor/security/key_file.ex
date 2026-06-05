defmodule Arbor.Security.KeyFile do
  @moduledoc """
  Parser for `.arbor.key` files — line-oriented key=value containers holding
  an agent_id + Ed25519 private key.

  Extracted from `Arbor.Gateway.Signer.ProxyCore` so this can be reused by
  other security-domain consumers (the scheduler `sign_caps` mix task,
  registration tooling, etc.) without crossing the Level-2 horizontal-dep
  boundary.

  ## File format

      agent_id=agent_30b455a27f7f4e02ef291fd9f7862677f731a1f8b08c997f5fb8ad430d594b6e
      private_key_b64=BASE64KEYBYTES==

  Whitespace around `=` is trimmed. Order is not significant. Lines that
  don't match the `key=value` shape are ignored (intentionally permissive
  to allow operator comments via convention, though comments aren't part
  of the format).
  """

  @typedoc """
  Parsed contents of a `.arbor.key` file.

    - `agent_id` — the cluster-registered agent id
    - `private_key` — the raw Ed25519 private key (32 or 64 bytes, decoded
      from base64)
  """
  @type key_material :: %{
          agent_id: String.t(),
          private_key: binary()
        }

  @doc """
  Parse `.arbor.key` file contents (as a binary).

  Returns `{:ok, key_material}` on success, or `{:error, reason}` for
  missing fields, invalid base64, or invalid agent_id shape.

  ## Errors

    - `{:missing_field, key}` — required field absent
    - `{:empty_field, key}` — field present but blank
    - `:invalid_private_key_base64` — value isn't valid base64
    - `{:invalid_private_key_size, n}` — decoded bytes don't fit Ed25519
    - `{:invalid_agent_id, value}` — doesn't start with `agent_`
  """
  @spec parse(String.t()) :: {:ok, key_material()} | {:error, atom() | tuple()}
  def parse(contents) when is_binary(contents) do
    fields =
      contents
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
          _ -> acc
        end
      end)

    with {:ok, agent_id} <- fetch_field(fields, "agent_id"),
         {:ok, private_key_b64} <- fetch_field(fields, "private_key_b64"),
         {:ok, private_key} <- decode_private_key(private_key_b64),
         :ok <- validate_agent_id(agent_id) do
      {:ok, %{agent_id: agent_id, private_key: private_key}}
    end
  end

  @doc """
  Read and parse a `.arbor.key` file from disk.

  Convenience over `parse/1` that handles the File.read step with a
  consistent error tuple shape.
  """
  @spec read(Path.t()) :: {:ok, key_material()} | {:error, atom() | tuple()}
  def read(path) do
    case File.read(path) do
      {:ok, contents} -> parse(contents)
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp fetch_field(fields, key) do
    case Map.get(fields, key) do
      nil -> {:error, {:missing_field, key}}
      "" -> {:error, {:empty_field, key}}
      value -> {:ok, value}
    end
  end

  defp decode_private_key(b64) do
    case Base.decode64(b64) do
      {:ok, bin} when byte_size(bin) in [32, 64] -> {:ok, bin}
      {:ok, bin} -> {:error, {:invalid_private_key_size, byte_size(bin)}}
      :error -> {:error, :invalid_private_key_base64}
    end
  end

  defp validate_agent_id(agent_id) do
    if String.starts_with?(agent_id, "agent_") and byte_size(agent_id) > 6 do
      :ok
    else
      {:error, {:invalid_agent_id, agent_id}}
    end
  end
end
