defmodule Arbor.Security.KeyFile do
  @moduledoc """
  Parser and serializer for `.arbor.key` files — line-oriented key=value
  containers holding a principal id + Ed25519 private key.

  Extracted from `Arbor.Gateway.Signer.ProxyCore` so this can be reused by
  other security-domain consumers (the scheduler `sign_caps` mix task,
  operator CLI proof, registration tooling, etc.) without crossing the
  Level-2 horizontal-dep boundary.

  ## File format

      agent_id=agent_30b455a27f7f4e02ef291fd9f7862677f731a1f8b08c997f5fb8ad430d594b6e
      private_key_b64=BASE64KEYBYTES==

  The field name remains `agent_id` for wire compatibility with existing
  `.arbor.key` files. The value may be an `agent_` or `human_` principal
  (an explicit allowlist — not "any non-empty id"). `human_` is required
  because `mix arbor.user.init` mints `human_<40 hex>` operator identities.

  Whitespace around `=` is trimmed. Order is not significant. Lines that
  don't match the `key=value` shape are ignored (intentionally permissive
  to allow operator comments via convention, though comments aren't part
  of the format).

  ## Private key material at rest

  Files are plaintext (no passphrase/keyring wrapping) and must be mode
  `0600`. Write refuses to overwrite an existing file. Read fails closed
  if the file is missing, unreadable, group/other-readable, or malformed.
  Callers must never log or echo `private_key` / `private_key_b64`.
  """

  import Bitwise

  @typedoc """
  Parsed contents of a `.arbor.key` file.

    - `agent_id` — the cluster-registered principal id (`agent_` or `human_`)
    - `private_key` — the raw Ed25519 private key (32 or 64 bytes, decoded
      from base64)
  """
  @type key_material :: %{
          agent_id: String.t(),
          private_key: binary()
        }

  # Keep this an allowlist of known principal prefixes. Do not loosen it to
  # "any non-empty id" — that would admit `system_authority` and other
  # non-principal locators into a private-key file.
  @known_principal_prefixes ["agent_", "human_"]

  @doc """
  Parse `.arbor.key` file contents (as a binary).

  Returns `{:ok, key_material}` on success, or `{:error, reason}` for
  missing fields, invalid base64, or invalid principal-id shape.

  ## Errors

    - `{:missing_field, key}` — required field absent
    - `{:empty_field, key}` — field present but blank
    - `:invalid_private_key_base64` — value isn't valid base64
    - `{:invalid_private_key_size, n}` — decoded bytes don't fit Ed25519
    - `{:invalid_agent_id, value}` — not in the `agent_` / `human_` allowlist
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
  Serialize key material to `.arbor.key` file contents.

  Pure. Does not write to disk. Inverse of `parse/1` for well-formed
  material (parse may ignore comments that serialize does not emit).
  """
  @spec serialize(key_material()) :: {:ok, String.t()} | {:error, atom() | tuple()}
  def serialize(%{agent_id: agent_id, private_key: private_key})
      when is_binary(agent_id) and is_binary(private_key) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- validate_private_key_size(private_key) do
      {:ok, "agent_id=#{agent_id}\nprivate_key_b64=#{Base.encode64(private_key)}\n"}
    end
  end

  def serialize(_), do: {:error, :invalid_key_material}

  @doc """
  Read and parse a `.arbor.key` file from disk.

  Fails closed for a missing file, unreadable file, group/other-readable
  mode, or malformed contents. Never returns key material from an
  insecure file.
  """
  @spec read(Path.t()) :: {:ok, key_material()} | {:error, atom() | tuple()}
  def read(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path),
         :ok <- assert_private_mode(stat),
         {:ok, contents} <- File.read(path) do
      parse(contents)
    else
      {:error, :enoent} -> {:error, {:read_failed, :enoent}}
      {:error, :eacces} -> {:error, {:read_failed, :eacces}}
      {:error, reason} when is_atom(reason) -> {:error, {:read_failed, reason}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Write key material to `path` as a new `0600` file.

  Refuses to overwrite an existing file (`{:error, :already_exists}`).
  Creates parent directories as needed. Never logs the private key.
  """
  @spec write(Path.t(), key_material()) :: {:ok, String.t()} | {:error, atom() | tuple()}
  def write(path, key_material) when is_binary(path) do
    abs = Path.expand(path)

    with {:ok, contents} <- serialize(key_material),
         :ok <- mkdir_parent(abs),
         :ok <- exclusive_write_private(abs, contents) do
      {:ok, abs}
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
      {:ok, bin} ->
        case validate_private_key_size(bin) do
          :ok -> {:ok, bin}
          error -> error
        end

      :error ->
        {:error, :invalid_private_key_base64}
    end
  end

  defp validate_private_key_size(key) when is_binary(key) and byte_size(key) in [32, 64], do: :ok

  defp validate_private_key_size(key) when is_binary(key),
    do: {:error, {:invalid_private_key_size, byte_size(key)}}

  defp validate_private_key_size(_), do: {:error, :invalid_key_material}

  defp validate_agent_id(agent_id) when is_binary(agent_id) do
    if known_principal_id?(agent_id) do
      :ok
    else
      {:error, {:invalid_agent_id, agent_id}}
    end
  end

  defp validate_agent_id(agent_id), do: {:error, {:invalid_agent_id, agent_id}}

  defp known_principal_id?(id) do
    Enum.any?(@known_principal_prefixes, fn prefix ->
      String.starts_with?(id, prefix) and byte_size(id) > byte_size(prefix)
    end)
  end

  defp assert_private_mode(%File.Stat{type: :regular, mode: mode}) do
    if band(mode, 0o077) == 0 do
      :ok
    else
      {:error, {:insecure_permissions, band(mode, 0o777)}}
    end
  end

  defp assert_private_mode(%File.Stat{type: type}), do: {:error, {:not_a_regular_file, type}}
  defp assert_private_mode(_), do: {:error, {:read_failed, :einval}}

  defp mkdir_parent(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp exclusive_write_private(path, contents) do
    case :file.open(path, [:raw, :binary, :write, :exclusive]) do
      {:ok, io} ->
        write_opened_private_file(path, io, contents)

      {:error, :eexist} ->
        {:error, :already_exists}

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  defp write_opened_private_file(path, io, contents) do
    result =
      case :file.change_mode(path, 0o600) do
        :ok ->
          case :file.write(io, contents) do
            :ok -> :ok
            {:error, reason} -> {:error, {:write_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:write_failed, reason}}
      end

    _ = :file.close(io)

    case result do
      :ok ->
        :ok

      {:error, _} = error ->
        _ = File.rm(path)
        error
    end
  end
end
