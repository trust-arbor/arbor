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

  alias Arbor.Common.Config
  alias Arbor.Common.SkillLibrary.{EmbeddingText, FabricAdapter, RawAdapter, SkillAdapter}

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

  When the configured persistence seam reports `:postgres` capability, delegates
  to hybrid BM25 + pgvector search. Otherwise falls back to ETS keyword matching.

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
    {:ok, %{results: results}} = search_with_meta(query, opts)
    results
  end

  @doc """
  Search with additive metadata for all fallback and zero-result states.

  Does not change the list-return contract of `search/2`.
  """
  @spec search_with_meta(String.t(), keyword()) ::
          {:ok, %{results: [term()], meta: map()}}
  def search_with_meta(query, opts \\ []) when is_binary(query) do
    # Snapshot capability once for this public search decision.
    cap = skill_capability()

    cond do
      Keyword.get(opts, :hybrid) == false ->
        ets_search_with_meta(query, opts, cap, :hybrid_forced_off)

      cap == :postgres ->
        postgres_hybrid_search(query, opts)

      true ->
        ets_search_with_meta(query, opts, cap)
    end
  end

  @doc """
  Hybrid search via the configured persistence seam.

  Falls back to ETS keyword search when persistence is not Postgres-capable.
  """
  @impl Arbor.Contracts.SkillLibrary
  def hybrid_search(query, opts \\ []) when is_binary(query) do
    {:ok, %{results: results}} = hybrid_search_with_meta(query, opts)
    results
  end

  @doc """
  Hybrid search with truthful metadata (additive concrete API).
  """
  @spec hybrid_search_with_meta(String.t(), keyword()) ::
          {:ok, %{results: [term()], meta: map()}}
  def hybrid_search_with_meta(query, opts \\ []) when is_binary(query) do
    # Snapshot capability once for this public search decision.
    cap = skill_capability()

    case cap do
      :postgres ->
        postgres_hybrid_search(query, opts)

      other ->
        ets_search_with_meta(query, opts, other)
    end
  end

  @doc """
  Sync all cached skills to the persistent store.

  On `:postgres`, computes embeddings through the configured embedding module
  and persists vectors + embedding_space. On outage, omits both keys so prior
  vectors are preserved. On `:ets_only`, upserts text-only without embedding.
  On `:unavailable`, returns `{:ok, 0}`.
  """
  @impl Arbor.Contracts.SkillLibrary
  def sync_to_store(_opts \\ []) do
    case skill_capability() do
      :unavailable ->
        {:ok, 0}

      :ets_only ->
        sync_text_only()

      :postgres ->
        sync_with_embeddings()
    end
  rescue
    e ->
      Logger.warning("[SkillLibrary] sync_to_store failed: #{Exception.message(e)}")
      {:error, :sync_failed}
  catch
    :exit, _reason ->
      Logger.warning("[SkillLibrary] sync_to_store exit")
      {:error, :sync_failed}
  end

  # force_reason:
  #   nil — default reason derived from capability
  #   :hybrid_forced_off — caller passed hybrid: false (may be Postgres-capable)
  defp ets_search_with_meta(query, opts, capability, force_reason \\ nil) do
    downcased = String.downcase(query)

    results =
      @table
      |> ets_all()
      |> filter(Keyword.take(opts, [:category]))
      |> Enum.map(fn skill -> {relevance_score(skill, downcased), skill} end)
      |> Enum.filter(fn {score, _skill} -> score > 0 end)
      |> Enum.sort_by(fn {score, _skill} -> score end, :desc)
      |> maybe_limit(Keyword.get(opts, :limit))
      |> Enum.map(fn {_score, skill} -> skill end)

    {arm_state, reason} = ets_meta_arms_and_reason(capability, force_reason, results)
    backend = if capability == :unavailable, do: :none, else: :ets

    {:ok,
     %{
       results: results,
       meta: %{
         mode: :ets_keyword,
         backend: backend,
         capability: capability,
         query_embedding: :not_attempted,
         bm25_arm: arm_state,
         vector_arm: arm_state,
         fusion: :none,
         result_count: length(results),
         reason: reason
       }
     }}
  end

  defp ets_meta_arms_and_reason(_capability, :hybrid_forced_off, _results) do
    {:skipped_forced_off, :hybrid_forced_off}
  end

  defp ets_meta_arms_and_reason(:unavailable, _force, _results) do
    {:skipped_not_postgres, :persistence_unavailable}
  end

  defp ets_meta_arms_and_reason(:ets_only, _force, _results) do
    {:skipped_not_postgres, :sqlite_or_non_postgres}
  end

  defp ets_meta_arms_and_reason(:postgres, _force, results) do
    # Postgres-capable but fell through to ETS without explicit hybrid: false
    # (e.g. search error fallback). Do not claim skipped_not_postgres.
    reason = if results == [], do: :zero_results, else: nil
    {:not_attempted, reason}
  end

  defp ets_meta_arms_and_reason(_capability, _force, _results) do
    {:skipped_not_postgres, :persistence_unavailable}
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
    # Schedule startup sync from the configured seam; retry while persistence is not ready.
    # (common boots before persistence — capability may be :unavailable at first.)
    schedule_startup_sync()
    {:noreply, state}
  end

  def handle_info({:sync_to_store_attempt, attempt}, state) when is_integer(attempt) do
    handle_startup_sync_attempt(attempt)
    {:noreply, state}
  end

  # Legacy immediate message (kept for compatibility with any external senders).
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
         {:ok, count} <- do_index(resolved, overwrite: false) do
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
    Application.get_env(:arbor_common, :skill_dirs) || default_skill_dirs()
  end

  @doc """
  Default skill directories, in precedence order. `maybe_insert/3` uses first-defined-wins, so
  EARLIER dirs override LATER ones — personal overrides project overrides bundled:

    1. `~/.agents/skills` — personal cross-tool skills (the vendor-neutral `.agents/` standard
       that Gemini CLI / agentskills.io converged on; shared across AI tools).
    2. `$ARBOR_HOME/library/skills` (default `~/.arbor/library/skills`) — personal Arbor skills,
       the writable per-install layer that survives system updates.
    3. `.agents/skills` (relative to cwd) — project cross-tool skills for this repo.
    4. Product skills bundled with `arbor_common` (`priv/library/skills`) — version-controlled +
       shipped inside `mix release` artifacts (`Application.app_dir/2` resolves the packaged path
       at runtime, `_build/.../priv/library/skills` in dev).

  A same-named skill in an earlier dir wins (so a user's `~/.arbor/library/skills/foo` overrides
  the bundled `foo`). Only existing directories are returned, so a missing tier is a no-op.
  `.claude/skills/` is deliberately NOT scanned — that's Claude-Code-CLI-scoped, not runtime-agent
  skills. Override the whole set via `config :arbor_common, :skill_dirs`.
  """
  @spec default_skill_dirs() :: [String.t()]
  def default_skill_dirs do
    arbor_home = System.get_env("ARBOR_HOME") || Path.expand("~/.arbor")

    [
      Path.expand("~/.agents/skills"),
      Path.join(arbor_home, "library/skills"),
      Path.expand(".agents/skills"),
      Application.app_dir(:arbor_common, "priv/library/skills")
    ]
    |> Enum.filter(&File.dir?/1)
  end

  defp skill_capability do
    case Config.skill_persistence_module() do
      nil ->
        :unavailable

      mod when is_atom(mod) ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :skill_search_capability, 0) do
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          case apply(mod, :skill_search_capability, []) do
            capability when capability in [:postgres, :ets_only, :unavailable] -> capability
            _unknown -> :unavailable
          end
        else
          :unavailable
        end

      _invalid ->
        # Bad config must not crash public search/sync paths.
        :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp postgres_hybrid_search(query, opts) do
    mod = Config.skill_persistence_module()

    with true <- is_atom(mod) and not is_nil(mod),
         true <- Code.ensure_loaded?(mod),
         true <- function_exported?(mod, :hybrid_search_skills_with_meta, 3) do
      {query_embedding, space, qstat} =
        case safe_embed(String.trim(query)) do
          {:ok, vec, space} -> {vec, space, :ok}
          :no_service -> {nil, nil, :no_service}
          :failed -> {nil, nil, :failed}
          :invalid -> {nil, nil, :invalid}
        end

      search_opts =
        if is_map(space) do
          Keyword.put(opts, :embedding_space, space)
        else
          opts
        end

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      {:ok, %{results: results, meta: meta}} =
        apply(mod, :hybrid_search_skills_with_meta, [query, query_embedding, search_opts])

      results = Enum.map(results, &rehydrate_skill/1)

      meta =
        meta
        |> Map.put(:query_embedding, qstat)
        |> Map.put(:result_count, length(results))

      meta =
        if results == [] and is_nil(meta[:reason]) and meta[:mode] in [:hybrid, :bm25_only] do
          Map.put(meta, :reason, :zero_results)
        else
          meta
        end

      {:ok, %{results: results, meta: meta}}
    else
      _ ->
        ets_search_with_meta(query, opts, :unavailable)
    end
  rescue
    _ ->
      ets_search_with_meta(query, opts, :postgres)
      |> put_search_error_reason()
  catch
    :exit, _ ->
      ets_search_with_meta(query, opts, :postgres)
      |> put_search_error_reason()
  end

  defp put_search_error_reason({:ok, %{results: results, meta: meta}}) do
    {:ok,
     %{
       results: results,
       meta:
         meta
         |> Map.put(:reason, :search_error)
         |> Map.put(:mode, :ets_keyword)
     }}
  end

  defp sync_text_only do
    mod = Config.skill_persistence_module()

    if is_atom(mod) and Code.ensure_loaded?(mod) and function_exported?(mod, :upsert_skills, 1) do
      attrs_list = Enum.map(ets_all(@table), &skill_to_sync_attrs/1)
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(mod, :upsert_skills, [attrs_list])
    else
      {:ok, 0}
    end
  end

  defp sync_with_embeddings do
    mod = Config.skill_persistence_module()

    if is_atom(mod) and Code.ensure_loaded?(mod) and function_exported?(mod, :upsert_skill, 1) do
      count =
        Enum.reduce(ets_all(@table), 0, fn skill, acc ->
          attrs = skill_to_sync_attrs(skill)

          # Always re-embed on sync. Skipping on content_hash alone is incorrect when
          # provider/model/dimensions change: exact-space filtering would hide old
          # vectors and they would never be backfilled. Current space is only known
          # after embed/2, so conservative packet-correct behavior is re-embed.
          attrs =
            case safe_embed(EmbeddingText.for_skill(skill)) do
              {:ok, vec, space} ->
                attrs
                |> Map.put(:embedding, vec)
                |> Map.put(:embedding_space, space)

              _ ->
                # Omit embedding and embedding_space — preserve prior vector/space.
                attrs
            end

          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          case apply(mod, :upsert_skill, [attrs]) do
            {:ok, _} -> acc + 1
            {:error, _} -> acc
          end
        end)

      {:ok, count}
    else
      {:ok, 0}
    end
  end

  defp skill_to_sync_attrs(skill) do
    skill_map = if is_struct(skill), do: Map.from_struct(skill), else: skill

    %{
      name: skill_field(skill_map, :name),
      description: skill_field(skill_map, :description, ""),
      body: skill_field(skill_map, :body, ""),
      tags: skill_field(skill_map, :tags, []),
      category: skill_field(skill_map, :category),
      source: to_string(skill_field(skill_map, :source, "skill")),
      path: skill_field(skill_map, :path),
      license: skill_field(skill_map, :license),
      compatibility: skill_field(skill_map, :compatibility),
      allowed_tools: skill_field(skill_map, :allowed_tools, []),
      content_hash: skill_field(skill_map, :content_hash) || content_hash(skill_map),
      taint: to_string(skill_field(skill_map, :taint, "trusted")),
      provenance: skill_field(skill_map, :provenance, %{}),
      metadata: skill_field(skill_map, :metadata, %{})
    }
  end

  defp skill_field(skill, key, default \\ nil) do
    Map.get(skill, key) || Map.get(skill, to_string(key)) || default
  end

  defp content_hash(skill) do
    body = Map.get(skill, :body) || Map.get(skill, "body") || ""
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  end

  defp safe_embed(text) when is_binary(text) do
    case resolve_embedding_module() do
      :no_service ->
        :no_service

      {:ok, mod} ->
        expected = Config.skill_embedding_dimensions()

        if is_integer(expected) and expected > 0 do
          try do
            # Request provider output in the admitted dimension space.
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            case apply(mod, :embed, [text, [dimensions: expected]]) do
              {:ok, result} -> validate_embed_result(result, expected)
              {:error, _} -> :failed
              _ -> :failed
            end
          rescue
            _ -> :failed
          catch
            :exit, _ -> :failed
          end
        else
          :invalid
        end
    end
  end

  defp resolve_embedding_module do
    case Config.skill_embedding_module() do
      mod when is_atom(mod) and not is_nil(mod) ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :embed, 2) do
          {:ok, mod}
        else
          :no_service
        end

      _ ->
        :no_service
    end
  end

  defp validate_embed_result(result, expected) when is_map(result) do
    embedding = Map.get(result, :embedding) || Map.get(result, "embedding")
    dimensions = Map.get(result, :dimensions) || Map.get(result, "dimensions")
    model = Map.get(result, :model) || Map.get(result, "model")
    provider = Map.get(result, :provider) || Map.get(result, "provider")

    case {
      valid_embedding?(embedding, expected),
      valid_reported_dimensions?(dimensions, expected),
      nonblank_model?(model),
      nonblank_provider?(provider)
    } do
      {true, true, true, true} ->
        space = %{
          "provider" => provider_to_string(provider),
          "model" => String.trim(to_string(model)),
          "dimensions" => length(embedding)
        }

        {:ok, embedding, space}

      _ ->
        :invalid
    end
  end

  defp validate_embed_result(_, _), do: :invalid

  defp valid_embedding?(embedding, expected) when is_list(embedding) and is_integer(expected) do
    expected > 0 and embedding != [] and length(embedding) == expected and
      Enum.all?(embedding, &is_number/1)
  end

  defp valid_embedding?(_embedding, _expected), do: false

  defp valid_reported_dimensions?(nil, _expected), do: true
  defp valid_reported_dimensions?(expected, expected), do: true
  defp valid_reported_dimensions?(_dimensions, _expected), do: false

  defp nonblank_model?(model) when is_binary(model), do: String.trim(model) != ""
  defp nonblank_model?(_), do: false

  defp nonblank_provider?(provider) when is_atom(provider) and not is_nil(provider), do: true

  defp nonblank_provider?(provider) when is_binary(provider), do: String.trim(provider) != ""

  defp nonblank_provider?(_), do: false

  defp provider_to_string(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_to_string(provider) when is_binary(provider), do: String.trim(provider)

  defp rehydrate_skill(%{name: name} = result) when is_binary(name) do
    case ets_lookup(name) do
      {:ok, skill} -> skill
      :error -> result
    end
  end

  defp rehydrate_skill(%{"name" => name} = result) when is_binary(name) do
    case ets_lookup(name) do
      {:ok, skill} -> skill
      :error -> result
    end
  end

  defp rehydrate_skill(other), do: other

  # Schedule startup sync when a persistence seam is configured, without requiring
  # live persistence readiness. Capability is re-checked on each attempt.
  defp schedule_startup_sync do
    case Config.skill_persistence_module() do
      nil ->
        :ok

      mod when is_atom(mod) ->
        Process.send_after(
          self(),
          {:sync_to_store_attempt, 1},
          Config.skill_sync_initial_delay_ms()
        )

      _invalid ->
        # Invalid configured seam must not crash SkillLibrary init.
        Logger.debug("[SkillLibrary] ignoring invalid skill_persistence_module config")
        :ok
    end
  end

  defp handle_startup_sync_attempt(attempt) do
    case skill_capability() do
      cap when cap in [:postgres, :ets_only] ->
        sync_to_store()

      :unavailable ->
        max = Config.skill_sync_max_attempts()

        if attempt < max do
          Process.send_after(
            self(),
            {:sync_to_store_attempt, attempt + 1},
            Config.skill_sync_retry_delay_ms()
          )
        else
          Logger.debug(
            "[SkillLibrary] startup sync gave up after #{attempt} attempts " <>
              "(persistence unavailable)"
          )
        end

      _other ->
        # Defensive: unexpected capability values never crash the GenServer.
        :ok
    end
  end
end
