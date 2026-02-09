defmodule Arbor.Security.Store.JSONFile do
  @moduledoc """
  JSON file-backed storage backend.

  Implements `Arbor.Contracts.Persistence.Store` using JSON files on disk.
  Each key maps to a single JSON file in the configured base directory.

  ## Configuration

      config :arbor_security, Arbor.Security.Store.JSONFile,
        base_dir: ".arbor/security"

  ## Key Namespacing

  Keys can include a namespace prefix separated by `:` which maps to
  subdirectories. For example, `"identities:agent_abc123"` stores to
  `{base_dir}/identities/agent_abc123.json`.

  Keys without a namespace store directly in the base directory.
  """

  @behaviour Arbor.Contracts.Persistence.Store

  require Logger

  @default_base_dir ".arbor/security"

  @impl true
  def put(key, value, opts \\ []) do
    path = key_to_path(key, opts)

    with :ok <- File.mkdir_p!(Path.dirname(path)),
         {:ok, json} <- Jason.encode(value, pretty: true) do
      File.write(path, json)
    end
  rescue
    e ->
      Logger.warning("JSONFile store put failed for #{key}: #{inspect(e)}")
      {:error, e}
  end

  @impl true
  def get(key, opts \\ []) do
    path = key_to_path(key, opts)

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(key, opts \\ []) do
    path = key_to_path(key, opts)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list(opts \\ []) do
    namespace = Keyword.get(opts, :namespace)
    dir = namespace_dir(namespace, opts)

    case File.ls(dir) do
      {:ok, files} ->
        keys =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(fn file ->
            base = String.trim_trailing(file, ".json")
            if namespace, do: "#{namespace}:#{base}", else: base
          end)

        {:ok, keys}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def exists?(key, opts \\ []) do
    path = key_to_path(key, opts)
    File.exists?(path)
  end

  # --- Path helpers ---

  defp key_to_path(key, opts) do
    base_dir = resolve_base_dir(opts)

    case String.split(key, ":", parts: 2) do
      [namespace, name] ->
        Path.join([base_dir, namespace, "#{name}.json"])

      [name] ->
        Path.join(base_dir, "#{name}.json")
    end
  end

  defp namespace_dir(nil, opts), do: resolve_base_dir(opts)

  defp namespace_dir(namespace, opts) do
    Path.join(resolve_base_dir(opts), namespace)
  end

  defp resolve_base_dir(opts) do
    dir =
      Keyword.get(opts, :base_dir) ||
        Application.get_env(:arbor_security, __MODULE__, [])
        |> Keyword.get(:base_dir, @default_base_dir)

    Path.join(File.cwd!(), dir)
  end
end
