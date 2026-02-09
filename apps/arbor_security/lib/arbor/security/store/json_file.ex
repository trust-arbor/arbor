defmodule Arbor.Security.Store.JSONFile do
  @moduledoc """
  JSON file-backed storage backend.

  Implements `Arbor.Contracts.Persistence.Store` using JSON files on disk.
  Each record maps to a single JSON file in the configured base directory,
  organized by namespace subdirectories.

  ## Configuration

      config :arbor_security, Arbor.Security.Store.JSONFile,
        base_dir: ".arbor/security"

  ## Namespace Convention

  Pass `name: "identities"` in opts to scope storage to a subdirectory.
  For example, with key `"agent_abc123"` and `name: "identities"`:

      {base_dir}/identities/agent_abc123.json

  Keys without a namespace store directly in the base directory.
  """

  @behaviour Arbor.Contracts.Persistence.Store

  require Logger

  alias Arbor.Contracts.Persistence.Record

  @default_base_dir ".arbor/security"

  @impl true
  def put(key, %Record{} = record, opts \\ []) do
    path = key_to_path(key, opts)
    value = %{"data" => record.data, "metadata" => record.metadata}

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
          {:ok, %{"data" => data} = envelope} ->
            record = %Record{
              id: key,
              key: key,
              data: data,
              metadata: envelope["metadata"] || %{}
            }

            {:ok, record}

          {:error, reason} ->
            {:error, reason}
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
    dir = namespace_dir(opts)

    case File.ls(dir) do
      {:ok, files} ->
        keys =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(&String.trim_trailing(&1, ".json"))

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
    dir = namespace_dir(opts)
    Path.join(dir, "#{key}.json")
  end

  defp namespace_dir(opts) do
    base_dir = resolve_base_dir(opts)

    case Keyword.get(opts, :name) do
      nil -> base_dir
      name -> Path.join(base_dir, to_string(name))
    end
  end

  defp resolve_base_dir(opts) do
    dir =
      Keyword.get(opts, :base_dir) ||
        Application.get_env(:arbor_security, __MODULE__, [])
        |> Keyword.get(:base_dir, @default_base_dir)

    Path.join(File.cwd!(), dir)
  end
end
