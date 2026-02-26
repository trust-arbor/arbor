defmodule Arbor.Agent.ProfileStore do
  @moduledoc """
  Durable profile storage backed by `Arbor.Persistence.BufferedStore`.

  Provides ETS-cached reads with pluggable durable persistence (Postgres by
  default, ETS-only in tests). Profiles are stored as serialized maps wrapped
  in `%Record{}` structs.

  ## Dual-Read Fallback

  `load_profile/1` tries the store first, then falls back to the legacy
  `.arbor/agents/*.agent.json` files. On fallback hit, the profile is
  lazy-migrated into the store so subsequent reads are fast.

  ## Supervision

  Started as a `BufferedStore` child in `Arbor.Agent.Application`.
  The store name is `:arbor_agent_profiles`.
  """

  alias Arbor.Agent.Profile
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.BufferedStore

  require Logger

  @store_name :arbor_agent_profiles
  @legacy_dir ".arbor/agents"

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Store an agent profile.

  Serializes the profile and persists via BufferedStore (ETS + backend).
  """
  @spec store_profile(Profile.t()) :: :ok | {:error, term()}
  def store_profile(%Profile{agent_id: agent_id} = profile) do
    if available?() do
      record = %Record{
        id: agent_id,
        key: agent_id,
        data: Profile.serialize(profile),
        metadata: %{}
      }

      BufferedStore.put(agent_id, record, name: @store_name)
    else
      {:error, :store_unavailable}
    end
  end

  @doc """
  Load an agent profile by ID.

  Tries the store first, falls back to legacy JSON file. On fallback hit,
  lazy-migrates the profile into the store.
  """
  @spec load_profile(String.t()) :: {:ok, Profile.t()} | {:error, :not_found | term()}
  def load_profile(agent_id) when is_binary(agent_id) do
    case load_from_store(agent_id) do
      {:ok, _profile} = ok ->
        ok

      {:error, :not_found} ->
        load_from_json_fallback(agent_id)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  List all stored profiles.

  Returns profiles from the BufferedStore ETS cache.
  Falls back to legacy JSON scan if the store is unavailable.
  """
  @spec list_profiles() :: [Profile.t()]
  def list_profiles do
    if available?() do
      {:ok, keys} = BufferedStore.list(name: @store_name)

      keys
      |> Enum.map(&load_from_store/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, profile} -> profile end)
    else
      list_from_json_fallback()
    end
  end

  @doc """
  List all profiles with `auto_start: true`.
  """
  @spec list_auto_start_profiles() :: [Profile.t()]
  def list_auto_start_profiles do
    list_profiles()
    |> Enum.filter(& &1.auto_start)
  end

  @doc """
  Delete a profile from the store.
  """
  @spec delete_profile(String.t()) :: :ok
  def delete_profile(agent_id) when is_binary(agent_id) do
    if available?() do
      BufferedStore.delete(agent_id, name: @store_name)
    end

    # Also remove legacy JSON file if it exists
    path = legacy_profile_path(agent_id)
    File.rm(path)

    :ok
  end

  @doc """
  Check if the ProfileStore is running.
  """
  @spec available?() :: boolean()
  def available? do
    Process.whereis(@store_name) != nil
  end

  @doc """
  Migrate legacy JSON profiles into the store.

  Scans `.arbor/agents/*.agent.json` and stores any profiles not already
  present in the BufferedStore. Idempotent — safe to call multiple times.
  """
  @spec migrate_json_profiles() :: {:ok, non_neg_integer()}
  def migrate_json_profiles do
    if available?() do
      do_migrate_json_profiles()
    else
      {:ok, 0}
    end
  end

  defp do_migrate_json_profiles do
    dir = legacy_agents_dir()

    case File.ls(dir) do
      {:ok, files} ->
        count =
          files
          |> Enum.filter(&String.ends_with?(&1, ".agent.json"))
          |> Enum.reject(&profile_exists_in_store?/1)
          |> Enum.count(&migrate_single_profile/1)

        {:ok, count}

      {:error, _} ->
        {:ok, 0}
    end
  end

  defp profile_exists_in_store?(file) do
    agent_id = String.replace_suffix(file, ".agent.json", "")
    BufferedStore.exists?(agent_id, name: @store_name)
  end

  defp migrate_single_profile(file) do
    agent_id = String.replace_suffix(file, ".agent.json", "")

    case read_json_profile(agent_id) do
      {:ok, profile} ->
        store_profile(profile)
        true

      {:error, _} ->
        false
    end
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp load_from_store(agent_id) do
    if available?() do
      case BufferedStore.get(agent_id, name: @store_name) do
        {:ok, raw} ->
          data = unwrap_record(raw)
          Profile.deserialize(data)

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  defp load_from_json_fallback(agent_id) do
    case read_json_profile(agent_id) do
      {:ok, profile} ->
        # Lazy-migrate into store
        if available?() do
          store_profile(profile)
        end

        {:ok, profile}

      {:error, _} = error ->
        error
    end
  end

  defp read_json_profile(agent_id) do
    path = legacy_profile_path(agent_id)

    case File.read(path) do
      {:ok, json} ->
        Profile.from_json(json)

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp list_from_json_fallback do
    dir = legacy_agents_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".agent.json"))
        |> Enum.map(fn file ->
          agent_id = String.replace_suffix(file, ".agent.json", "")
          read_json_profile(agent_id)
        end)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, profile} -> profile end)

      {:error, _} ->
        []
    end
  end

  # Record struct from backend (loaded from disk after restart)
  defp unwrap_record(%Record{data: data}), do: data
  # Plain map from ETS (stored during current session)
  defp unwrap_record(%{} = data), do: data

  defp legacy_profile_path(agent_id) do
    Path.join(legacy_agents_dir(), "#{agent_id}.agent.json")
  end

  defp legacy_agents_dir do
    Path.join(File.cwd!(), @legacy_dir)
  end
end
