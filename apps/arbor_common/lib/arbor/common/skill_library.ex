defmodule Arbor.Common.SkillLibrary do
  @moduledoc """
  File-based skill library backed by ETS for fast lookups.

  Scans configured directories for skill definitions using adapters
  (`SkillAdapter`, `FabricAdapter`, `RawAdapter`), parses each file
  into an `Arbor.Contracts.Skill` struct, and caches the results in
  a `:public` ETS table (`:arbor_skill_library`) for zero-cost reads.

  ## Adapters

  Each directory is scanned by **all** adapters — each adapter finds
  only the files it recognises:

  - `SkillAdapter` — `**/SKILL.md` files with YAML frontmatter
  - `FabricAdapter` — `**/system.md` Fabric patterns
  - `RawAdapter` — loose `.md` / `.txt` files not claimed by the above

  ## Configuration

      config :arbor_common, :skill_dirs, [".arbor/skills"]

  Directories are resolved relative to `File.cwd!/0` unless absolute.

  ## Public API

  `get/1`, `list/1`, `search/2`, and `count/0` read directly from ETS —
  no GenServer round-trip required. `register/1` and `index/2` write
  through the GenServer to ensure serialised mutation.

  ## Supervision

  Add to your supervision tree:

      children = [
        Arbor.Common.SkillLibrary
      ]

  """

  use GenServer

  require Logger

  alias Arbor.Common.SkillLibrary.{FabricAdapter, RawAdapter, SkillAdapter}

  @behaviour Arbor.Contracts.SkillLibrary

  @table :arbor_skill_library

  @adapters [SkillAdapter, FabricAdapter, RawAdapter]

  # ---------------------------------------------------------------------------
  # Public API — reads go straight to ETS
  # ---------------------------------------------------------------------------

  @doc """
  Retrieve a skill by its unique name.

  Returns `{:ok, skill}` if found, `{:error, :not_found}` otherwise.

  ## Examples

      iex> Arbor.Common.SkillLibrary.get("code-review")
      {:ok, %Arbor.Contracts.Skill{name: "code-review", ...}}

      iex> Arbor.Common.SkillLibrary.get("nonexistent")
      {:error, :not_found}

  """
  @impl Arbor.Contracts.SkillLibrary
  @spec get(String.t()) :: {:ok, Arbor.Contracts.SkillLibrary.skill()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    case ets_lookup(name) do
      {:ok, skill} -> {:ok, skill}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  List skills matching the given filter options.

  ## Options

  - `:category` — filter by category string
  - `:tags` — filter by tags; skills must have at least one matching tag
  - `:source` — filter by source atom (`:skill`, `:fabric`, `:raw`)

  Returns all skills when no options are provided.

  ## Examples

      iex> Arbor.Common.SkillLibrary.list(category: "advisory")
      [%Arbor.Contracts.Skill{category: "advisory", ...}, ...]

  """
  @impl Arbor.Contracts.SkillLibrary
  @spec list(keyword()) :: [Arbor.Contracts.SkillLibrary.skill()]
  def list(opts \\ []) do
    @table
    |> ets_all()
    |> filter(opts)
  end

  @doc """
  Search for skills by keyword query.

  When `Arbor.Persistence.SkillSearch` is available, delegates to hybrid
  BM25 + pgvector search. Otherwise falls back to ETS keyword matching.

  Results are sorted by relevance:

  1. Name match (weight 4)
  2. Description match (weight 3)
  3. Tag match (weight 2)
  4. Body match (weight 1)

  ## Options

  - `:limit` — maximum number of results (default: unlimited)
  - `:category` — restrict search to a specific category
  - `:hybrid` — force hybrid search when true, ETS when false (default: auto)

  ## Examples

      iex> Arbor.Common.SkillLibrary.search("security")
      [%Arbor.Contracts.Skill{name: "security-perspective", ...}, ...]

  """
  @impl Arbor.Contracts.SkillLibrary
  @spec search(String.t(), keyword()) :: [Arbor.Contracts.SkillLibrary.skill()]
  def search(query, opts \\ []) when is_binary(query) do
    use_hybrid = Keyword.get(opts, :hybrid)

    if use_hybrid != false and hybrid_search_available?() do
      hybrid_search(query, opts)
    else
      ets_search(query, opts)
    end
  end

  @doc """
  Hybrid search delegating to persistence layer.

  Uses BM25 + pgvector via `Arbor.Persistence.SkillSearch`.
  Falls back to ETS keyword search if persistence is unavailable.
  """
  @impl Arbor.Contracts.SkillLibrary
  def hybrid_search(query, opts \\ []) when is_binary(query) do
    search_mod = Arbor.Persistence.SkillSearch

    if Code.ensure_loaded?(search_mod) and function_exported?(search_mod, :hybrid_search, 3) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(search_mod, :hybrid_search, [query, nil, opts])
    else
      ets_search(query, opts)
    end
  rescue
    _ -> ets_search(query, opts)
  catch
    :exit, _ -> ets_search(query, opts)
  end

  @doc """
  Sync all cached skills to the persistent store.

  Writes the current ETS cache to Postgres for hybrid search indexing.
  Runs asynchronously after ETS population.
  """
  @impl Arbor.Contracts.SkillLibrary
  def sync_to_store(_opts \\ []) do
    search_mod = Arbor.Persistence.SkillSearch

    if Code.ensure_loaded?(search_mod) and function_exported?(search_mod, :upsert_batch, 1) do
      skills = ets_all(@table)
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(search_mod, :upsert_batch, [skills])
    else
      {:ok, 0}
    end
  rescue
    e ->
      Logger.warning("[SkillLibrary] sync_to_store failed: #{inspect(e)}")
      {:error, e}
  catch
    :exit, reason ->
      Logger.warning("[SkillLibrary] sync_to_store exit: #{inspect(reason)}")
      {:error, reason}
  end

  # ETS-based keyword search (original implementation)
  defp ets_search(query, opts) do
    downcased = String.downcase(query)

    @table
    |> ets_all()
    |> filter(Keyword.take(opts, [:category]))
    |> Enum.map(fn skill -> {relevance_score(skill, downcased), skill} end)
    |> Enum.filter(fn {score, _skill} -> score > 0 end)
    |> Enum.sort_by(fn {score, _skill} -> score end, :desc)
    |> maybe_limit(Keyword.get(opts, :limit))
    |> Enum.map(fn {_score, skill} -> skill end)
  end

  @doc """
  Register a new skill in the library.

  Writes through the GenServer to ensure serialised mutation.
  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @impl Arbor.Contracts.SkillLibrary
  @spec register(Arbor.Contracts.SkillLibrary.skill()) :: :ok | {:error, term()}
  def register(skill) do
    GenServer.call(__MODULE__, {:register, skill})
  end

  @doc """
  Scan a directory and index all skill definitions found.

  Walks the directory with all adapters and registers every skill
  discovered. Writes through the GenServer.

  ## Options

  - `:recursive` — whether to scan subdirectories (default: `true`)
  - `:overwrite` — whether to overwrite existing skills (default: `false`)

  Returns `{:ok, count}` with the number of skills indexed.
  """
  @impl Arbor.Contracts.SkillLibrary
  @spec index(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def index(dir, opts \\ []) do
    GenServer.call(__MODULE__, {:index, dir, opts}, :timer.seconds(30))
  end

  @doc """
  Return the number of skills currently cached.
  """
  @spec count() :: non_neg_integer()
  def count do
    if :ets.whereis(@table) != :undefined do
      :ets.info(@table, :size)
    else
      0
    end
  end

  @doc """
  Force a re-scan of all configured skill directories.

  Clears the cache and re-indexes everything.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload, :timer.seconds(30))
  end

  # ---------------------------------------------------------------------------
  # GenServer — supervision
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # Create the ETS table — public + read_concurrency for lock-free reads
    create_table()

    dirs = Keyword.get(opts, :dirs) || configured_dirs()

    # Index asynchronously so init doesn't block supervision tree startup
    send(self(), {:scan_dirs, dirs})

    {:ok, %{dirs: dirs}}
  end

  @impl GenServer
  def handle_call({:register, skill}, _from, state) do
    result = do_register(skill)
    {:reply, result, state}
  end

  def handle_call({:index, dir, opts}, _from, state) do
    result = do_index(dir, opts)
    {:reply, result, state}
  end

  def handle_call(:reload, _from, state) do
    :ets.delete_all_objects(@table)
    scan_all_dirs(state.dirs)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:scan_dirs, dirs}, state) do
    scan_all_dirs(dirs)
    # Async sync to persistent store for hybrid search
    maybe_async_sync()
    {:noreply, state}
  end

  def handle_info(:sync_to_store, state) do
    sync_to_store()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[SkillLibrary] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Internal — table management
  # ---------------------------------------------------------------------------

  defp create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  defp ets_lookup(name) do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, name) do
        [{^name, skill}] -> {:ok, skill}
        [] -> :error
      end
    else
      :error
    end
  end

  defp ets_all(table) do
    if :ets.whereis(table) != :undefined do
      :ets.tab2list(table)
      |> Enum.map(fn {_name, skill} -> skill end)
    else
      []
    end
  end

  defp ets_insert(name, skill) do
    :ets.insert(@table, {name, skill})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internal — scanning & indexing
  # ---------------------------------------------------------------------------

  defp scan_all_dirs(dirs) do
    dirs
    |> Enum.map(&resolve_dir/1)
    |> Enum.each(&scan_one_dir/1)
  end

  defp scan_one_dir(resolved) when is_binary(resolved) do
    with true <- File.dir?(resolved),
         {:ok, count} <- do_index(resolved, overwrite: true) do
      if count > 0, do: Logger.info("[SkillLibrary] Indexed #{count} skills from #{resolved}")
    else
      false ->
        Logger.debug("[SkillLibrary] Skill directory not found: #{resolved}")

      {:error, reason} ->
        Logger.warning("[SkillLibrary] Failed to index #{resolved}: #{inspect(reason)}")
    end
  end

  defp do_index(dir, opts) when is_binary(dir) do
    if File.dir?(dir) do
      overwrite? = Keyword.get(opts, :overwrite, false)

      count =
        @adapters
        |> Enum.flat_map(fn adapter -> adapter.list(dir) end)
        |> Enum.uniq()
        |> Enum.reduce(0, &index_one_file(&1, overwrite?, &2))

      {:ok, count}
    else
      {:error, {:not_a_directory, dir}}
    end
  end

  defp index_one_file(path, overwrite?, acc) do
    adapter = adapter_for(path)

    case adapter.parse(path) do
      {:ok, skill} -> maybe_insert(skill, overwrite?, acc)
      {:error, reason} -> log_skip(path, reason, acc)
    end
  end

  defp maybe_insert(skill, overwrite?, acc) do
    name = skill_name(skill)

    if overwrite? or ets_lookup(name) == :error do
      ets_insert(name, skill)
      acc + 1
    else
      acc
    end
  end

  defp log_skip(path, reason, acc) do
    Logger.debug("[SkillLibrary] Skipping #{path}: #{inspect(reason)}")
    acc
  end

  defp do_register(skill) do
    name = skill_name(skill)

    if name && is_binary(name) && byte_size(name) > 0 do
      ets_insert(name, skill)
    else
      {:error, {:invalid_skill, "skill must have a non-empty name"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal — adapter selection
  # ---------------------------------------------------------------------------

  # Select the right adapter based on file path.
  defp adapter_for(path) do
    basename = Path.basename(path)

    cond do
      basename == "SKILL.md" -> SkillAdapter
      basename == "system.md" -> FabricAdapter
      true -> RawAdapter
    end
  end

  # ---------------------------------------------------------------------------
  # Internal — filtering & search scoring
  # ---------------------------------------------------------------------------

  defp filter(skills, opts) do
    skills
    |> filter_category(Keyword.get(opts, :category))
    |> filter_tags(Keyword.get(opts, :tags))
    |> filter_source(Keyword.get(opts, :source))
  end

  defp filter_category(skills, nil), do: skills

  defp filter_category(skills, category) do
    Enum.filter(skills, fn skill ->
      skill_field(skill, :category) == category
    end)
  end

  defp filter_tags(skills, nil), do: skills
  defp filter_tags(skills, []), do: skills

  defp filter_tags(skills, tags) when is_list(tags) do
    tag_set = MapSet.new(tags)

    Enum.filter(skills, fn skill ->
      skill_tags = skill_field(skill, :tags) || []
      skill_tags |> MapSet.new() |> MapSet.intersection(tag_set) |> MapSet.size() > 0
    end)
  end

  defp filter_source(skills, nil), do: skills

  defp filter_source(skills, source) do
    Enum.filter(skills, fn skill ->
      skill_field(skill, :source) == source
    end)
  end

  @doc false
  @spec relevance_score(map() | struct(), String.t()) :: non_neg_integer()
  def relevance_score(skill, downcased_query) do
    name = String.downcase(skill_field(skill, :name) || "")
    desc = String.downcase(skill_field(skill, :description) || "")
    body = String.downcase(skill_field(skill, :body) || "")

    tags =
      (skill_field(skill, :tags) || [])
      |> Enum.map(&String.downcase/1)

    score = 0
    score = if String.contains?(name, downcased_query), do: score + 4, else: score
    score = if String.contains?(desc, downcased_query), do: score + 3, else: score

    score =
      if Enum.any?(tags, &String.contains?(&1, downcased_query)),
        do: score + 2,
        else: score

    score = if String.contains?(body, downcased_query), do: score + 1, else: score

    score
  end

  # ---------------------------------------------------------------------------
  # Internal — helpers
  # ---------------------------------------------------------------------------

  defp maybe_limit(list, nil), do: list
  defp maybe_limit(list, limit) when is_integer(limit) and limit > 0, do: Enum.take(list, limit)
  defp maybe_limit(list, _), do: list

  # Extract a field from either a struct or a plain map.
  defp skill_name(skill), do: skill_field(skill, :name)

  defp skill_field(%{} = skill, field) when is_atom(field) do
    Map.get(skill, field)
  end

  defp resolve_dir(dir) when is_binary(dir) do
    if Path.type(dir) == :absolute do
      dir
    else
      Path.join(File.cwd!(), dir)
    end
  end

  defp configured_dirs do
    Application.get_env(:arbor_common, :skill_dirs, [".arbor/skills"])
  end

  defp hybrid_search_available? do
    mod = Arbor.Persistence.SkillSearch
    Code.ensure_loaded?(mod) and function_exported?(mod, :hybrid_search, 3)
  end

  defp maybe_async_sync do
    if hybrid_search_available?() do
      # Delay sync slightly to avoid contention during startup
      Process.send_after(self(), :sync_to_store, 1_000)
    end
  end
end
