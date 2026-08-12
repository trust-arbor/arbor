defmodule Arbor.Contracts.Census do
  @moduledoc """
  Executable consumer census for `arbor_contracts` (AC-1.0 / AC-02).

  Lives at `lib/arbor/contracts_census.ex` so it is **outside** the scanned
  subtree `lib/arbor/contracts/**` and does not self-enroll.

  ## Entry fields (exact)

  - `:path` — app-relative under `apps/arbor_contracts/`
    (e.g. `lib/arbor/contracts/security/capability.ex`)
  - `:modules` — every column-0 `defmodule` in the file
  - `:loc` — physical line count
  - `:external_consumers` — sorted umbrella app names (not `arbor_contracts`)
  - `:internal_consumers` — sorted app-relative paths under `arbor_contracts`
    (`lib/...` and `test/...`) that reference this file
  - `:in_registry` — module appears in `lib/arbor/contracts.ex` `list_contracts/0`
  - `:callbacks` — `@callback` count
  - `:tier` — `:a | :a2 | :b | :c | :d | :shared`

  ## Tier decision table (exact order)

  1. path under `lib/arbor/contracts/api/` → `:c`
  2. ≥2 external consumer apps → `:shared`
  3. `callbacks > 0` → `:b`
  4. zero external consumers → `:d`
  5. one external with remaining **blocking** internal consumers → `:a2`
  6. otherwise → `:a`

  Blocking internal references include lib and test paths, exclude
  `lib/arbor/contracts.ex`, and exempt only same-destination files that remain
  Tier A after conservative fixed-point classification.

  The canonical grandfather inventory lives here because both the Mix task and
  admission test enforce it. The test owns the default `:warn` mode and proves
  the inventory remains identical to the dated AC-02 fixture.
  """

  alias Arbor.Contracts.Coding.SourceInventory

  @contracts_app "arbor_contracts"
  @contracts_prefix "lib/arbor/contracts/"
  @registry_rel "lib/arbor/contracts.ex"
  @registry_umbrella "apps/arbor_contracts/lib/arbor/contracts.ex"
  @valid_tiers [:a, :a2, :b, :c, :d, :shared]
  @tier_sort_order %{a: 0, a2: 1, b: 2, c: 3, d: 4, shared: 5}

  # This inventory is runtime policy, not test-only fixture data: the Mix task
  # needs the same exceptions as the admission test when enforce mode is used.
  @default_grandfathered Map.new([
                           {"lib/arbor/contracts/session/behavior.ex",
                            "AC-03 evicts to arbor_orchestrator"},
                           {"lib/arbor/contracts/coding/reconciliation_manifest.ex",
                            "AC-03 evicts to arbor_orchestrator"},
                           {"lib/arbor/contracts/session/assistant_message.ex",
                            "AC-03 evicts to arbor_orchestrator"},
                           {"lib/arbor/contracts/session/state.ex",
                            "AC-03 evicts to arbor_orchestrator"},
                           {"lib/arbor/contracts/session/config.ex",
                            "AC-03 evicts to arbor_orchestrator"},
                           {"lib/arbor/contracts/session/heartbeat_result.ex",
                            "AC-03 evicts to arbor_orchestrator"},
                           {"lib/arbor/contracts/session/turn_authority.ex",
                            "AC-03 evicts to arbor_orchestrator"},
                           {"lib/arbor/contracts/llm/budget_snapshot.ex",
                            "AC-04 evicts to arbor_ai"},
                           {"lib/arbor/contracts/ai/response.ex", "AC-04 evicts to arbor_ai"},
                           {"lib/arbor/contracts/ai/request.ex", "AC-04 evicts to arbor_ai"},
                           {"lib/arbor/contracts/ai/runtime_profile.ex",
                            "AC-04 evicts to arbor_ai"},
                           {"lib/arbor/contracts/consensus/code_review_request.ex",
                            "AC-05 evicts to arbor_actions"},
                           {"lib/arbor/contracts/judge/rubric.ex",
                            "AC-05 evicts to arbor_actions"},
                           {"lib/arbor/contracts/consensus/events.ex",
                            "AC-06 evicts to arbor_consensus"},
                           {"lib/arbor/contracts/consensus/agent_mailbox.ex",
                            "AC-06 evicts to arbor_consensus"},
                           {"lib/arbor/contracts/security/reflex.ex",
                            "AC-07 evicts to arbor_security"},
                           {"lib/arbor/contracts/security/invocation_receipt.ex",
                            "AC-07 evicts to arbor_security"},
                           {"lib/arbor/contracts/trust/event.ex", "AC-07 evicts to arbor_trust"},
                           {"lib/arbor/contracts/eval/outcome.ex", "AC-08 evicts to arbor_agent"},
                           {"lib/arbor/contracts/agent/spec.ex", "AC-08 evicts to arbor_agent"},
                           {"lib/arbor/contracts/capability_match.ex",
                            "AC-08 evicts to arbor_common"},
                           {"lib/arbor/contracts/coding/source_inventory.ex", "AC-12 pending"},
                           {"lib/arbor/contracts/consensus/consensus_event.ex", "AC-12 pending"},
                           {"lib/arbor/contracts/persistence/vector_receipt.ex", "AC-12 pending"},
                           {"lib/arbor/contracts/llm/control_plane_support.ex", "AC-12 pending"},
                           {"lib/arbor/contracts/llm/auth_provenance.ex", "AC-12 pending"},
                           {"lib/arbor/contracts/consensus/invariants.ex", "AC-12 pending"},
                           {"lib/arbor/contracts/security/signing_authority/validator.ex",
                            "AC-12 pending"},
                           {"lib/arbor/contracts/agent/config.ex", "AC-12 pending"},
                           {"lib/arbor/contracts/judge/evidence.ex", "AC-12 pending"},
                           {"lib/arbor/contracts/handler/scoped_context.ex", "AC-12 pending"},
                           {"lib/arbor/contracts/libraries/cartographer.ex", "AC-09 review"},
                           {"lib/arbor/contracts/consensus/protocol.ex", "AC-09 review"},
                           {"lib/arbor/contracts/skill_library.ex", "AC-09 review"},
                           {"lib/arbor/contracts/comms/response_router.ex", "AC-09 review"},
                           {"lib/arbor/contracts/judge/evidence_producer.ex", "AC-09 review"},
                           {"lib/arbor/contracts/handler/registry.ex", "AC-09 review"},
                           {"lib/arbor/contracts/security/sanitizer.ex", "AC-09 review"},
                           {"lib/arbor/contracts/checkpoint.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/signal/event.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/error.ex", "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/session/message.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/session/turn.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/session/context_key.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/persistence/vector_validation.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/ai/error.ex", "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/session/tool_call.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/agent/authority.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/memory/types.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/ai/resource_budget.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/session/adapter.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/agent/context.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/consensus/change_proposal.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/comms/question.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/healing/anomaly_queue.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/healing/fingerprint.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/comms/question_registry.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/handler/computable.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/handler/writeable.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/handler/composable.ex",
                            "AC-10 blocked on runtime census"},
                           {"lib/arbor/contracts/handler/compute_policy.ex",
                            "AC-10 blocked on runtime census"}
                         ])

  @type tier :: :a | :a2 | :b | :c | :d | :shared

  @type entry :: %{
          path: String.t(),
          modules: [String.t()],
          loc: non_neg_integer(),
          external_consumers: [String.t()],
          internal_consumers: [String.t()],
          in_registry: boolean(),
          callbacks: non_neg_integer(),
          tier: tier()
        }

  @type report :: %{
          generated_at: String.t(),
          root: String.t(),
          contract_file_count: non_neg_integer(),
          entries: [entry()],
          violations: [entry()],
          mode: :warn | :enforce,
          summary: map()
        }

  @doc "Valid tier atoms."
  @spec valid_tiers() :: [tier()]
  def valid_tiers, do: @valid_tiers

  @doc "Canonical temporary admission exceptions from the 2026-08-10 census."
  @spec default_grandfathered() :: %{String.t() => String.t()}
  def default_grandfathered, do: @default_grandfathered

  @doc """
  Run the census.

  Options:
  - `:root` — umbrella root
  - `:mode` — `:warn` (default) or `:enforce`
  - `:tier` — atom, list of atoms, or comma-separated string (`"a,b,shared"`)
  - `:grandfathered` — `%{path => justification}` map (from admission test)
  - `:env` — contained-mode env map
  - `:now` — `DateTime` for `generated_at`
  - `:contract_sources` / `:consumer_sources` — hermetic test overrides
  - `:registry_source` — override contracts.ex body for tests
  - `:preamble` — markdown preamble to preserve when formatting
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    root = Keyword.get_lazy(opts, :root, &umbrella_root/0)
    mode = Keyword.get(opts, :mode, :warn)
    env = Keyword.get_lazy(opts, :env, &inventory_env_from_system/0)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    grandfathered =
      opts
      |> Keyword.get(:grandfathered, @default_grandfathered)
      |> normalize_grandfathered()

    tier_filter = parse_tier_filter(Keyword.get(opts, :tier))

    with {:ok, contract_sources} <- load_contract_sources(root, env, opts),
         {:ok, consumer_sources} <- load_consumer_sources(root, env, opts),
         {:ok, registry_mods} <- load_registry_modules(root, opts) do
      all_entries = build_entries(contract_sources, consumer_sources, registry_mods)
      entries = filter_tiers(all_entries, tier_filter)

      violations =
        Enum.filter(all_entries, fn e ->
          admission_violation?(e) and not Map.has_key?(grandfathered, e.path)
        end)

      report = %{
        generated_at: DateTime.to_iso8601(now),
        root: root,
        contract_file_count: length(all_entries),
        entries: entries,
        violations: violations,
        mode: mode,
        summary: summarize(all_entries, violations)
      }

      {:ok, report}
    end
  end

  @doc "True when enforce mode must fail."
  @spec failed?(report()) :: boolean()
  def failed?(%{mode: :enforce, violations: v}), do: v != []
  def failed?(%{mode: :warn}), do: false
  def failed?(_), do: false

  @doc "Format report as `:text`, `:json`, or `:markdown`."
  @spec format(report(), :text | :json | :markdown, keyword()) :: String.t()
  def format(report, style, opts \\ [])

  def format(report, :json, _opts) do
    report
    |> json_safe()
    |> Jason.encode!(pretty: true)
  end

  def format(report, :text, _opts), do: format_text(report)

  def format(report, :markdown, opts) do
    preamble =
      Keyword.get(opts, :preamble) ||
        default_markdown_preamble()

    format_markdown(report, preamble)
  end

  @doc "Expand `alias Foo.{Bar, Baz}` into fully-qualified module names."
  @spec expand_brace_aliases(String.t()) :: [String.t()]
  def expand_brace_aliases(source) when is_binary(source) do
    ~r/alias\s+([A-Z][\w.]*)\.\{([^}]+)\}/
    |> Regex.scan(source)
    |> Enum.flat_map(fn [_, prefix, body] ->
      body
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn leaf ->
        leaf = leaf |> String.split(~r/\s+as\s+/) |> hd() |> String.trim()
        prefix <> "." <> leaf
      end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Extract column-0 `defmodule` names only (no leading whitespace).

  Nested/indented modules are intentionally ignored.
  """
  @spec extract_modules(String.t()) :: [String.t()]
  def extract_modules(source) when is_binary(source) do
    ~r/^defmodule\s+([A-Z][\w.]*)/m
    |> Regex.scan(source)
    |> Enum.map(fn [_, n] -> n end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Physical LOC (all lines, including blanks)."
  @spec physical_loc(String.t()) :: non_neg_integer()
  def physical_loc(""), do: 0

  def physical_loc(source) when is_binary(source) do
    source
    |> String.split("\n", trim: false)
    |> length()
  end

  @doc "Count `@callback` lines."
  @spec count_callbacks(String.t()) :: non_neg_integer()
  def count_callbacks(source) when is_binary(source) do
    ~r/^\s*@callback\b/m
    |> Regex.scan(source)
    |> length()
  end

  @doc "Whether consumer_path is the mirrored own-test for contract_path (app-relative)."
  @spec own_mirrored_test?(String.t(), String.t()) :: boolean()
  def own_mirrored_test?(contract_rel, consumer_rel)
      when is_binary(contract_rel) and is_binary(consumer_rel) do
    expected =
      contract_rel
      |> String.replace_prefix(@contracts_prefix, "test/arbor/contracts/")
      |> String.replace_suffix(".ex", "_test.exs")

    consumer_rel == expected
  end

  @doc "Parse modules listed in Arbor.Contracts.list_contracts/0 source."
  @spec parse_registry_modules(String.t()) :: MapSet.t(String.t())
  def parse_registry_modules(source) when is_binary(source) do
    ~r/\bArbor\.Contracts\.[A-Z][\w.]*/
    |> Regex.scan(source)
    |> List.flatten()
    |> MapSet.new()
  end

  @doc """
  True when source references declared_mod or any arbitrary-depth descendant.

  Matches `Mod`, `Mod.Child`, `Mod.Child.Grandchild`, …
  """
  @spec module_or_descendant_mentioned?(String.t(), String.t()) :: boolean()
  def module_or_descendant_mentioned?(source, declared_mod)
      when is_binary(source) and is_binary(declared_mod) do
    tokens = extract_reference_tokens(source)

    Enum.any?(tokens, fn tok ->
      tok == declared_mod or String.starts_with?(tok, declared_mod <> ".")
    end)
  end

  @doc "Extract module-reference tokens once from source (brace aliases + dotted names)."
  @spec extract_reference_tokens(String.t()) :: MapSet.t(String.t())
  def extract_reference_tokens(source) when is_binary(source) do
    brace = expand_brace_aliases(source)

    # Ordinary aliases (non-brace).
    ordinary =
      ~r/(?:^|[^\w.])alias\s+([A-Z][\w.]*)(?:[^\w.{]|$)/m
      |> Regex.scan(source)
      |> Enum.map(fn [_, name] -> name end)

    # Drop incomplete brace heads (`Foo` from `alias Foo.{Bar}`).
    brace_heads =
      ~r/alias\s+([A-Z][\w.]*)\.\{/
      |> Regex.scan(source)
      |> Enum.map(fn [_, p] -> p end)

    ordinary = ordinary -- brace_heads

    # Any dotted Module.Path token (covers direct refs, types, @behaviour, etc.).
    dotted =
      ~r/(?:^|[^\w.])([A-Z][\w]*(?:\.[A-Z][\w]*)+)/
      |> Regex.scan(source)
      |> Enum.map(fn [_, m] -> m end)

    (brace ++ ordinary ++ dotted)
    |> MapSet.new()
  end

  # --- loading ---------------------------------------------------------------

  defp load_contract_sources(root, env, opts) do
    case Keyword.fetch(opts, :contract_sources) do
      {:ok, sources} when is_list(sources) ->
        {:ok, normalize_contract_sources(sources)}

      :error ->
        with {:ok, paths} <- tracked_paths(root, env, &contract_scan_path?/1) do
          {:ok,
           Enum.map(paths, fn umbrella_path ->
             rel = app_relative(umbrella_path)
             {rel, File.read!(Path.join(root, umbrella_path))}
           end)}
        end
    end
  end

  defp normalize_contract_sources(sources) do
    Enum.map(sources, fn
      {path, source} ->
        rel =
          cond do
            String.starts_with?(path, "apps/arbor_contracts/") ->
              app_relative(path)

            String.starts_with?(path, @contracts_prefix) ->
              path

            String.starts_with?(path, "lib/") ->
              path

            true ->
              @contracts_prefix <> String.trim_leading(path, "/")
          end

        {rel, source}
    end)
  end

  defp load_consumer_sources(root, env, opts) do
    case Keyword.fetch(opts, :consumer_sources) do
      {:ok, sources} when is_list(sources) ->
        {:ok,
         Enum.map(sources, fn {path, source} ->
           {normalize_consumer_path(path), source}
         end)}

      :error ->
        with {:ok, paths} <- tracked_paths(root, env, &consumer_scan_path?/1) do
          {:ok,
           Enum.map(paths, fn p ->
             {p, File.read!(Path.join(root, p))}
           end)}
        end
    end
  end

  defp normalize_consumer_path(path) do
    if String.starts_with?(path, "apps/"), do: path, else: path
  end

  defp load_registry_modules(root, opts) do
    case Keyword.fetch(opts, :registry_source) do
      {:ok, source} when is_binary(source) ->
        {:ok, parse_registry_modules(source)}

      :error ->
        path = Path.join(root, @registry_umbrella)

        case File.read(path) do
          {:ok, source} -> {:ok, parse_registry_modules(source)}
          {:error, reason} -> {:error, {:registry_read, reason}}
        end
    end
  end

  defp contract_scan_path?(path) do
    String.starts_with?(path, "apps/arbor_contracts/" <> @contracts_prefix) and
      String.ends_with?(path, ".ex")
  end

  defp consumer_scan_path?(path) do
    String.starts_with?(path, "apps/") and
      (String.contains?(path, "/lib/") or String.contains?(path, "/test/")) and
      (String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs"))
  end

  defp app_relative("apps/arbor_contracts/" <> rest), do: rest
  defp app_relative(path), do: path

  defp tracked_paths(root, env, filter) when is_function(filter, 1) do
    case Map.get(env, "ARBOR_MIX_CONTAINED") do
      "1" ->
        contained_paths(env, filter)

      _ ->
        case System.cmd("git", ["-C", root, "ls-files", "apps/"], stderr_to_stdout: true) do
          {out, 0} ->
            {:ok,
             out
             |> String.split("\n", trim: true)
             |> Enum.filter(filter)
             |> Enum.sort()}

          {err, code} ->
            {:error, {:git_ls_files_failed, code, err}}
        end
    end
  end

  defp contained_paths(env, filter) do
    case resolve_source_inventory_path(env) do
      {:error, reason} ->
        {:error, {:source_inventory, reason}}

      {:ok, path} ->
        max_bytes = SourceInventory.max_encoded_bytes()

        with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
             :ok <- admit_manifest_byte_size(size, max_bytes),
             {:ok, bytes} <- File.read(path),
             {:ok, decoded} <- Jason.decode(bytes),
             {:ok, inventory} <- SourceInventory.new(decoded) do
          {:ok,
           inventory
           |> SourceInventory.paths()
           |> Enum.filter(filter)
           |> Enum.sort()}
        else
          {:error, reason} -> {:error, {:source_inventory, reason}}
          other -> {:error, {:source_inventory, other}}
        end
    end
  end

  defp resolve_source_inventory_path(env) when is_map(env) do
    case Map.fetch(env, "ARBOR_SOURCE_INVENTORY_PATH") do
      {:ok, path} when is_binary(path) and path != "" -> {:ok, path}
      {:ok, _} -> {:error, :invalid_inventory_path}
      :error -> {:error, :missing_inventory_path}
    end
  end

  defp admit_manifest_byte_size(size, max)
       when is_integer(size) and is_integer(max) and size >= 0 and max > 0 do
    if size <= max, do: :ok, else: {:error, :oversized_manifest}
  end

  defp inventory_env_from_system do
    %{}
    |> put_env_if_present("ARBOR_MIX_CONTAINED")
    |> put_env_if_present("ARBOR_SOURCE_INVENTORY_PATH")
  end

  defp put_env_if_present(map, key) do
    case System.get_env(key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  # --- build entries ---------------------------------------------------------

  defp build_entries(contract_sources, consumer_sources, registry_mods) do
    module_to_path =
      Enum.reduce(contract_sources, %{}, fn {path, source}, acc ->
        Enum.reduce(extract_modules(source), acc, fn mod, inner ->
          Map.put(inner, mod, path)
        end)
      end)

    all_modules = module_to_path |> Map.keys() |> MapSet.new()

    # Extract reference tokens ONCE per consumer source (timeout fix).
    consumers =
      Enum.map(consumer_sources, fn {umbrella_or_rel, source} ->
        umbrella = normalize_consumer_umbrella(umbrella_or_rel)
        app = app_from_path(umbrella)
        tokens = extract_reference_tokens(source)

        %{
          umbrella: umbrella,
          app_rel: if(app == @contracts_app, do: app_relative(umbrella), else: nil),
          app: app,
          refs: match_candidates(tokens, all_modules)
        }
      end)

    # Every tracked contract source produces one entry.
    prelim =
      Enum.map(contract_sources, fn {path, source} ->
        modules = extract_modules(source)
        module_set = MapSet.new(modules)

        external =
          consumers
          |> Enum.filter(fn c ->
            c.app != @contracts_app and
              MapSet.size(MapSet.intersection(c.refs, module_set)) > 0
          end)
          |> Enum.map(& &1.app)
          |> Enum.uniq()
          |> Enum.sort()

        internal =
          consumers
          |> Enum.filter(fn c ->
            c.app == @contracts_app and
              is_binary(c.app_rel) and
              c.app_rel != path and
              not own_mirrored_test?(path, c.app_rel) and
              MapSet.size(MapSet.intersection(c.refs, module_set)) > 0
          end)
          |> Enum.map(& &1.app_rel)
          |> Enum.uniq()
          |> Enum.sort()

        in_registry = Enum.any?(modules, &MapSet.member?(registry_mods, &1))

        %{
          path: path,
          modules: modules,
          loc: physical_loc(source),
          external_consumers: external,
          internal_consumers: internal,
          in_registry: in_registry,
          callbacks: count_callbacks(source),
          api?: String.starts_with?(path, @contracts_prefix <> "api/")
        }
      end)

    tier_by_path = classify_all_tiers(prelim)

    prelim
    |> Enum.map(fn e ->
      %{
        path: e.path,
        modules: e.modules,
        loc: e.loc,
        external_consumers: e.external_consumers,
        internal_consumers: e.internal_consumers,
        in_registry: e.in_registry,
        callbacks: e.callbacks,
        tier: Map.fetch!(tier_by_path, e.path)
      }
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp match_candidates(%MapSet{} = tokens, %MapSet{} = candidates) do
    candidates
    |> Enum.filter(fn cand ->
      Enum.any?(tokens, fn tok ->
        tok == cand or String.starts_with?(tok, cand <> ".")
      end)
    end)
    |> MapSet.new()
  end

  defp normalize_consumer_umbrella(path) do
    cond do
      String.starts_with?(path, "apps/") ->
        path

      String.starts_with?(path, "lib/") or String.starts_with?(path, "test/") ->
        "apps/arbor_contracts/" <> path

      true ->
        path
    end
  end

  defp classify_all_tiers(prelim) do
    by_path = Map.new(prelim, &{&1.path, &1})

    movable_a =
      fixed_point_movable_a(
        prelim
        |> Enum.filter(fn e ->
          not e.api? and e.callbacks == 0 and length(e.external_consumers) == 1
        end)
        |> MapSet.new(& &1.path),
        by_path
      )

    Map.new(prelim, fn e ->
      {e.path, classify_tier(e, movable_a)}
    end)
  end

  defp fixed_point_movable_a(candidates, by_path) do
    reduced =
      candidates
      |> Enum.filter(fn path ->
        e = Map.fetch!(by_path, path)
        sole = hd(e.external_consumers)
        blocking_internals(e, sole, candidates, by_path) == []
      end)
      |> MapSet.new()

    if MapSet.equal?(reduced, candidates) do
      reduced
    else
      fixed_point_movable_a(reduced, by_path)
    end
  end

  defp blocking_internals(entry, sole_external, movable_candidates, by_path) do
    Enum.reject(entry.internal_consumers, fn consumer_path ->
      cond do
        consumer_path == @registry_rel ->
          true

        not Map.has_key?(by_path, consumer_path) ->
          # test/ paths and non-contract lib paths always block
          false

        MapSet.member?(movable_candidates, consumer_path) ->
          other = Map.fetch!(by_path, consumer_path)
          other.external_consumers == [sole_external]

        true ->
          false
      end
    end)
  end

  # Exact AC-02 decision table (order is load-bearing).
  defp classify_tier(%{api?: true}, _movable_a), do: :c

  defp classify_tier(e, movable_a) do
    n_ext = length(e.external_consumers)

    cond do
      n_ext >= 2 -> :shared
      e.callbacks > 0 -> :b
      n_ext == 0 -> :d
      MapSet.member?(movable_a, e.path) -> :a
      true -> :a2
    end
  end

  defp admission_violation?(%{tier: :shared}), do: false
  defp admission_violation?(%{tier: :c, callbacks: callbacks}), do: callbacks == 0

  defp admission_violation?(%{path: path}) when is_binary(path) do
    not String.starts_with?(path, @contracts_prefix <> "api/")
  end

  defp parse_tier_filter(nil), do: nil
  defp parse_tier_filter(tier) when is_atom(tier), do: MapSet.new([tier])

  defp parse_tier_filter(tiers) when is_list(tiers) do
    tiers
    |> Enum.map(&normalize_tier/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp parse_tier_filter(tiers) when is_binary(tiers) do
    tiers
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&normalize_tier/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp parse_tier_filter(_), do: nil

  defp normalize_tier(t) when is_atom(t) do
    if t in @valid_tiers, do: t, else: nil
  end

  defp normalize_tier(t) when is_binary(t) do
    a = String.to_existing_atom(t)
    if a in @valid_tiers, do: a, else: nil
  rescue
    ArgumentError -> nil
  end

  defp normalize_tier(_), do: nil

  defp filter_tiers(entries, nil), do: entries

  defp filter_tiers(entries, %MapSet{} = set) do
    if MapSet.size(set) == 0 do
      entries
    else
      Enum.filter(entries, &MapSet.member?(set, &1.tier))
    end
  end

  defp normalize_grandfathered(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {normalize_gf_path(k), v}
      {k, v} -> {normalize_gf_path(to_string(k)), v}
    end)
  end

  defp normalize_grandfathered(_), do: %{}

  defp normalize_gf_path(path) do
    cond do
      String.starts_with?(path, "apps/arbor_contracts/") -> app_relative(path)
      String.starts_with?(path, @contracts_prefix) -> path
      String.starts_with?(path, "lib/") -> path
      true -> @contracts_prefix <> String.trim_leading(path, "/")
    end
  end

  defp summarize(entries, violations) do
    by_tier =
      entries
      |> Enum.group_by(& &1.tier)
      |> Map.new(fn {k, v} -> {k, length(v)} end)

    loc_by_tier =
      entries
      |> Enum.group_by(& &1.tier)
      |> Map.new(fn {k, v} -> {k, Enum.reduce(v, 0, &(&1.loc + &2))} end)

    %{
      total: length(entries),
      violations: length(violations),
      by_tier: by_tier,
      loc_by_tier: loc_by_tier,
      total_loc: Enum.reduce(entries, 0, &(&1.loc + &2)),
      total_callbacks: Enum.reduce(entries, 0, &(&1.callbacks + &2)),
      tier_a: Map.get(by_tier, :a, 0),
      tier_a2: Map.get(by_tier, :a2, 0),
      tier_b: Map.get(by_tier, :b, 0),
      tier_c: Map.get(by_tier, :c, 0),
      tier_d: Map.get(by_tier, :d, 0),
      tier_shared: Map.get(by_tier, :shared, 0)
    }
  end

  defp app_from_path(path) do
    case Path.split(path) do
      ["apps", app | _] -> app
      _ -> "unknown"
    end
  end

  defp umbrella_root, do: find_root(File.cwd!())

  defp find_root(dir) do
    cond do
      File.exists?(Path.join([dir, "apps", "arbor_contracts", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> raise "could not locate umbrella root from #{dir}"
      true -> find_root(Path.dirname(dir))
    end
  end

  # --- formatters ------------------------------------------------------------

  defp json_safe(report) do
    %{
      "generated_at" => report.generated_at,
      "root" => report.root,
      "contract_file_count" => report.contract_file_count,
      "mode" => Atom.to_string(report.mode),
      "summary" => stringify_keys(report.summary),
      "entries" => Enum.map(report.entries, &entry_json/1),
      "violations" => Enum.map(report.violations, &entry_json/1)
    }
  end

  defp entry_json(e) do
    %{
      "path" => e.path,
      "modules" => e.modules,
      "loc" => e.loc,
      "external_consumers" => e.external_consumers,
      "internal_consumers" => e.internal_consumers,
      "in_registry" => e.in_registry,
      "callbacks" => e.callbacks,
      "tier" => Atom.to_string(e.tier)
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp format_text(report) do
    s = report.summary

    header = """
    Arbor contracts census
    generated_at: #{report.generated_at}
    mode: #{report.mode}
    files: #{s.total}  violations: #{s.violations}
    by_tier: #{inspect(s.by_tier)}
    loc: #{s.total_loc}  callbacks: #{s.total_callbacks}
    loc_by_tier: #{inspect(s.loc_by_tier)}

    """

    body =
      report.entries
      |> Enum.group_by(& &1.tier)
      |> Enum.sort_by(fn {tier, _} -> Map.get(@tier_sort_order, tier, 99) end)
      |> Enum.map_join("\n", fn {tier, es} ->
        rows =
          es
          |> Enum.sort_by(fn e ->
            {Enum.join(e.external_consumers, ","), e.path}
          end)
          |> Enum.map_join("\n", fn e ->
            dest =
              case e.external_consumers do
                [] -> "(none)"
                apps -> Enum.join(apps, ",")
              end

            "#{e.path}\t#{e.tier}\t#{dest}\text=#{length(e.external_consumers)}\tint=#{length(e.internal_consumers)}\treg=#{e.in_registry}\tcb=#{e.callbacks}\tloc=#{e.loc}"
          end)

        "### tier #{tier}\npath\ttier\tdestination\text\tint\treg\tcb\tloc\n#{rows}"
      end)

    viol =
      if report.violations == [] do
        "\nNo admission violations.\n"
      else
        "\nViolations:\n" <>
          Enum.map_join(report.violations, "\n", fn e ->
            "  - #{e.path} tier=#{e.tier} ext=#{inspect(e.external_consumers)}"
          end) <> "\n"
      end

    header <> body <> "\n" <> viol
  end

  # Canonical dated CENSUS.md preamble (verbatim).
  defp default_markdown_preamble do
    """
    # `arbor_contracts` consumer census — 2026-08-10

    Generated from the umbrella at `HEAD` on 2026-08-10. **Do not hand-edit.**
    Regenerate with `./bin/mix arbor.contracts.census --format markdown` (AC-02 deliverable).

    ## Method

    Two independent counts per file under `apps/arbor_contracts/lib/arbor/contracts/`:

    - **External consumers** — umbrella apps *other than* `arbor_contracts` referencing any module
      the file declares, or a descendant of one. Decides **admissibility** (AC-1).
    - **Internal consumers** — other files *inside* `apps/arbor_contracts` (both `lib/` and `test/`)
      referencing the same. Decides **movability** (AC-11).

    Both counts expand brace aliases (`alias Arbor.Contracts.Security.{Taint, TaintEnvelope}`) before
    matching — 234 such sites exist and a naive regex misses all of them. A file's consumer set is the
    union across every module it declares; several files declare five.

    **These are different questions and conflating them is unsound.** A module with one external
    consumer is inadmissible; it is only *movable* if nothing left behind in L0 still needs it.
    13 of the 31 files that pass the admissibility test fail the movability test.

    **Known limitation:** static references only. A module reached solely by runtime `apply/3` or a
    config-injected atom shows as zero-consumer. This is why Tier D is blocked on
    `runtime-usage-census-and-performance-telemetry` and Tier A is not.
    """
  end

  defp format_markdown(report, preamble) do
    s = report.summary

    body = """
    ## Summary

    | Metric | Value |
    | --- | ---: |
    | Contract files | #{s.total} |
    | Admission violations | #{s.violations} |
    | Total LOC | #{s.total_loc} |
    | Total callbacks | #{s.total_callbacks} |
    | Tier A | #{s.tier_a} files / #{Map.get(s.loc_by_tier, :a, 0)} LOC |
    | Tier A2 | #{s.tier_a2} files / #{Map.get(s.loc_by_tier, :a2, 0)} LOC |
    | Tier B | #{s.tier_b} files / #{Map.get(s.loc_by_tier, :b, 0)} LOC |
    | Tier C | #{s.tier_c} files / #{Map.get(s.loc_by_tier, :c, 0)} LOC |
    | Tier D | #{s.tier_d} files / #{Map.get(s.loc_by_tier, :d, 0)} LOC |
    | Shared | #{s.tier_shared} files / #{Map.get(s.loc_by_tier, :shared, 0)} LOC |

    ### By tier

    #{tier_bullets(s.by_tier)}

    ## Inventory

    | path | modules | loc | external_consumers | internal_consumers | in_registry | callbacks | tier |
    | --- | --- | ---: | --- | --- | --- | ---: | --- |
    #{Enum.map_join(report.entries, "\n", &md_row/1)}

    ## Violations

    #{violations_md(report.violations)}
    """

    String.trim_trailing(preamble) <> "\n\n" <> body
  end

  defp tier_bullets(by_tier) when is_map(by_tier) do
    Enum.map_join(@valid_tiers, "\n", fn t ->
      "- **#{t}**: #{Map.get(by_tier, t, 0)}"
    end)
  end

  defp md_row(e) do
    mods = Enum.join(e.modules, ", ")
    ext = Enum.join(e.external_consumers, ", ")
    int = Enum.join(e.internal_consumers, ", ")

    "| `#{e.path}` | #{mods} | #{e.loc} | #{ext} | #{int} | #{e.in_registry} | #{e.callbacks} | #{e.tier} |"
  end

  defp violations_md([]), do: "_None._"

  defp violations_md(violations) do
    Enum.map_join(violations, "\n", fn e ->
      "- `#{e.path}` — tier=`#{e.tier}` external=#{inspect(e.external_consumers)}"
    end)
  end
end
