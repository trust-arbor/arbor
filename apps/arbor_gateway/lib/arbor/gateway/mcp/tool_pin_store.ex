defmodule Arbor.Gateway.MCP.ToolPinStore do
  @moduledoc """
  Durable JSON file store for accepted MCP tool-fingerprint pins.

  Gateway does not depend on `arbor_persistence` (its ETS/Agent backends are
  `:process_lifetime` anyway). Approvals already live in Security as
  capabilities; pins are not capabilities. This store follows the same
  conventions as those durable file stores: `SafePath`, exclusive temp file,
  mode `0600`, atomic rename. Durability class is `:node_restart` for the
  configured directory.

  ## Fail-closed load

  A missing file is a first run and loads as empty pins. An unreadable or
  corrupt file returns `{:error, :unreadable}` — callers must not treat that
  as empty pins and first-discover whatever the server now advertises.
  """

  alias Arbor.Common.SafePath
  alias Arbor.Gateway.MCP.ToolPinStoreCore

  @default_dir "~/.arbor/mcp_tool_pins"

  @doc "See `ToolPinStoreCore.identity/2`."
  @spec identity(String.t(), map()) :: String.t()
  def identity(server_name, config), do: ToolPinStoreCore.identity(server_name, config)

  @spec load(String.t(), keyword()) :: {:ok, map()} | {:error, :unreadable}
  def load(identity, opts \\ []) when is_binary(identity) and is_list(opts) do
    dir = root(opts)

    cond do
      not File.exists?(dir) ->
        {:ok, %{}}

      File.regular?(dir) ->
        {:error, :unreadable}

      File.dir?(dir) ->
        read_existing(dir, identity)

      true ->
        {:error, :unreadable}
    end
  end

  @spec save(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save(identity, pins, opts \\ [])
      when is_binary(identity) and is_map(pins) and is_list(opts) do
    with {:ok, contents} <- ToolPinStoreCore.encode(identity, pins),
         {:ok, path} <- prepare_path(identity, opts),
         :ok <- publish(path, contents) do
      :ok
    end
  end

  @spec drop(String.t(), keyword()) :: :ok | {:error, term()}
  def drop(identity, opts \\ []) when is_binary(identity) and is_list(opts) do
    dir = root(opts)

    cond do
      not File.exists?(dir) ->
        :ok

      File.dir?(dir) ->
        case SafePath.safe_join(dir, ToolPinStoreCore.file_name(identity)) do
          {:ok, path} ->
            case File.rm(path) do
              :ok -> :ok
              {:error, :enoent} -> :ok
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, :unreadable}
    end
  end

  defp read_existing(dir, identity) do
    case SafePath.safe_join(dir, ToolPinStoreCore.file_name(identity)) do
      {:ok, path} ->
        case File.read(path) do
          {:error, :enoent} -> {:ok, %{}}
          {:ok, contents} -> ToolPinStoreCore.decode(contents, identity)
          {:error, _} -> {:error, :unreadable}
        end

      {:error, _} ->
        {:error, :unreadable}
    end
  end

  defp prepare_path(identity, opts) do
    dir = root(opts)

    case File.mkdir_p(dir) do
      :ok -> SafePath.safe_join(dir, ToolPinStoreCore.file_name(identity))
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish(path, contents) do
    dir = Path.dirname(path)
    tmp = Path.join(dir, ".#{random_id()}.tmp")

    with :ok <- File.write(tmp, contents),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp root(opts) do
    case Keyword.get(opts, :dir) do
      dir when is_binary(dir) and dir != "" ->
        Path.expand(dir)

      _other ->
        case Application.get_env(:arbor_gateway, :mcp_tool_pin_dir, @default_dir) do
          dir when is_binary(dir) and dir != "" -> Path.expand(dir)
          _invalid -> Path.expand(@default_dir)
        end
    end
  end

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
