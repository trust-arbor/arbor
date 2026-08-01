defmodule Arbor.AI.Runtime.RouteInputAssembler do
  @moduledoc """
  Bounded production assembler for `ProviderRouter` inputs.

  Combines a closed reviewed routing profile with catalog, scoreboard,
  provider-observation, budget, and clock evidence. Structural admission for
  task registry, scoreboard, catalog ModelEntry contracts, and identifiers is
  owned by `Arbor.AI.Runtime.ProviderRouter` (`admit_task_registry/2`,
  `admit_scoreboard/1`, `admit_catalog/1`, `admit_task_class/1`,
  `admit_identifier/2`). This module keeps only assembler-specific concerns:
  profile load, catalog-source policy, explicit providers, evidence readers,
  and source-timestamp preservation.

  Default production observation assembly first computes exact admitted
  `%ModelEntry{}` OAuth candidates. When candidates are present it takes
  **one** supervised OAuth model-catalog cache snapshot and emits
  **model-specific** observations (never a generic provider-wide OAuth row
  that could wildcard-match sibling models). When there are zero OAuth
  candidates the snapshot is not read. Catalog membership for arbor OAuth
  routes is composed via `ProviderModelCatalogObservation`; non-arbor OAuth
  runtimes never borrow catalog evidence or relabel as arbor. Route
  selection never refreshes credentials or calls
  `Arbor.LLM.oauth_model_catalog`.

  Injectable `profile`/`clock`/readers are a **test seam only**. Production
  callers use `Arbor.AI.assemble_provider_route_input/1`, which loads the
  reviewed Application profile and production readers.
  """

  alias Arbor.AI.ProviderControlPlane
  alias Arbor.AI.RouteConcurrency
  alias Arbor.AI.RouteConcurrencyCore
  alias Arbor.AI.Runtime.RouteCatalog
  alias Arbor.AI.Runtime.OAuthHealthObservation
  alias Arbor.AI.Runtime.ProviderModelCatalogObservation
  alias Arbor.AI.Runtime.ProviderRouter
  alias Arbor.AI.Runtime.RouteEvidenceOverlay
  alias Arbor.Contracts.LLM.BudgetSnapshot
  alias Arbor.Contracts.LLM.ModelEntry
  alias Arbor.Contracts.LLM.ProviderEntry
  alias Arbor.Contracts.LLM.ProviderModelCatalog
  alias Arbor.Contracts.LLM.ProviderObservation

  @max_catalog 128
  @max_providers 128
  @max_observations 256
  @max_budgets 256
  @max_fallbacks 64
  @max_oauth_catalog_routes 2
  @oauth_catalog_routes MapSet.new(["openai_oauth", "xai_oauth"])
  @profile_keys ~w(
    enabled task_registry default_task_class catalog_model_ids catalog
    scoreboard providers fallback_limit params
  )a

  @type error ::
          :disabled
          | {:route_assembly_failed,
             :invalid_profile
             | :invalid_catalog
             | :invalid_scoreboard
             | :invalid_observation
             | :invalid_budget
             | :missing_budget
             | :invalid_task_class
             | :route_failure_evidence_unavailable
             | :route_failure_evidence_malformed
             | :quota_evidence_unavailable
             | :quota_evidence_malformed
             | :route_concurrency_evidence_unavailable
             | :route_concurrency_evidence_malformed
             | :oauth_model_catalog_evidence_unavailable
             | :oauth_model_catalog_evidence_malformed
             | :malformed}

  @doc """
  Assemble a strict `ProviderRouter` input from a reviewed profile and evidence.

  Options (test seam; production facade does not expose these to orchestrator):

    * `:profile` — override Application profile (test-only seam; may supply
      direct `%ModelEntry{}` catalog structs). Production Application config
      must use `catalog_model_ids` only.
    * `:clock` — zero-arity returning `%DateTime{}`
    * `:catalog_reader` — `(model_ids :: [String.t()]) -> {:ok, [ModelEntry.t()]} | {:error, term()}`
    * `:observation_reader` — `(providers, decision_time) -> {:ok, [ProviderObservation.t()]} | {:error, term()}`
      Injected two-arity seam bypasses default OAuth catalog snapshot/health wiring.
    * `:oauth_catalog_snapshot_reader` — `() -> {:ok, map()} | {:error, term()}`
      (default path only; production uses `Arbor.AI.oauth_model_catalog_snapshot/1`)
    * `:oauth_health_reader` — `(route) -> {:ok, health} | {:error, term()}`
      (default path only; production uses `Arbor.LLM.oauth_health/1`; memoized once per route)
    * `:budget_reader` — `(providers, decision_time) -> {:ok, [BudgetSnapshot.t()]} | {:error, term()}`
    * `:task_class` — bounded task class string
  """
  @spec assemble(keyword()) :: {:ok, map()} | {:error, error()}
  def assemble(opts \\ [])

  def assemble(opts) when is_list(opts) do
    test_profile_seam? = Keyword.has_key?(opts, :profile)

    with {:ok, profile} <- load_profile(opts),
         :ok <- ensure_enabled(profile),
         {:ok, decision_time} <- decision_time(opts),
         {:ok, task_class} <- resolve_task_class(opts, profile),
         {:ok, task_registry} <- resolve_task_registry(profile),
         {:ok, catalog} <- resolve_catalog(profile, opts, test_profile_seam?),
         {:ok, scoreboard} <- resolve_scoreboard(profile),
         {:ok, providers} <- resolve_providers(profile, catalog),
         {:ok, observations} <- resolve_observations(providers, decision_time, catalog, opts),
         {:ok, budgets} <- resolve_budgets(providers, decision_time, opts),
         {:ok, policy} <- build_policy(profile) do
      {:ok,
       %{
         task_class: task_class,
         task_registry: task_registry,
         catalog: catalog,
         scoreboard: scoreboard,
         observations: observations,
         budgets: budgets,
         now: decision_time,
         policy: policy
       }}
    end
  rescue
    _ -> {:error, {:route_assembly_failed, :malformed}}
  catch
    _, _ -> {:error, {:route_assembly_failed, :malformed}}
  end

  def assemble(_opts), do: {:error, {:route_assembly_failed, :malformed}}

  @doc false
  @spec production_requirements() :: {:ok, map()} | {:error, term()}
  def production_requirements do
    with {:ok, profile} <- load_profile([]) do
      if Map.get(profile, :enabled, false) do
        with :ok <- ensure_enabled(profile),
             {:ok, _task_class} <- resolve_task_class([], profile),
             {:ok, _task_registry} <- resolve_task_registry(profile),
             {:ok, catalog} <- resolve_catalog(profile, [], false),
             {:ok, _scoreboard} <- resolve_scoreboard(profile),
             {:ok, _providers} <- resolve_providers(profile, catalog),
             {:ok, _policy} <- build_policy(profile) do
          requirements_for_catalog(catalog)
        end
      else
        {:ok, %{enabled: false, required_routes: [], binding: []}}
      end
    end
  rescue
    _ -> {:error, {:route_assembly_failed, :malformed}}
  catch
    _, _ -> {:error, {:route_assembly_failed, :malformed}}
  end

  @doc false
  @spec requirements_for_catalog(term()) :: {:ok, map()} | {:error, term()}
  def requirements_for_catalog(catalog) when is_list(catalog) do
    candidates = oauth_route_candidates(catalog)

    binding =
      candidates
      |> Enum.map(fn candidate ->
        %{
          "route" => candidate.provider,
          "model_id" => candidate.ref,
          "runtime" => candidate.runtime
        }
      end)
      |> Enum.uniq()
      |> Enum.sort_by(fn candidate ->
        {candidate["route"], candidate["model_id"], candidate["runtime"]}
      end)

    {:ok,
     %{
       enabled: true,
       required_routes:
         binding
         |> Enum.map(& &1["route"])
         |> Enum.uniq()
         |> canonical_oauth_route_order(),
       binding: binding
     }}
  rescue
    _ -> {:error, {:route_assembly_failed, :malformed}}
  catch
    _, _ -> {:error, {:route_assembly_failed, :malformed}}
  end

  def requirements_for_catalog(_), do: {:error, {:route_assembly_failed, :malformed}}

  defp load_profile(opts) do
    case Keyword.fetch(opts, :profile) do
      {:ok, profile} -> normalize_profile(profile)
      :error -> normalize_profile(Application.get_env(:arbor_ai, :provider_route_profile))
    end
  end

  defp ensure_enabled(%{enabled: true}), do: :ok
  defp ensure_enabled(_profile), do: {:error, :disabled}

  defp normalize_profile(nil), do: {:ok, %{enabled: false}}

  defp normalize_profile(profile) when is_map(profile) and not is_struct(profile) do
    if map_size(profile) > 32 do
      {:error, {:route_assembly_failed, :invalid_profile}}
    else
      with {:ok, values} <- take_profile_fields(profile) do
        enabled = Map.get(values, :enabled, false)

        if enabled not in [true, false] do
          {:error, {:route_assembly_failed, :invalid_profile}}
        else
          {:ok, Map.put(values, :enabled, enabled)}
        end
      end
    end
  end

  defp normalize_profile(_), do: {:error, {:route_assembly_failed, :invalid_profile}}

  defp take_profile_fields(profile) do
    Enum.reduce_while(profile, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case canonical_profile_key(key) do
        {:ok, atom_key} ->
          if Map.has_key?(acc, atom_key) do
            {:halt, {:error, {:route_assembly_failed, :invalid_profile}}}
          else
            {:cont, {:ok, Map.put(acc, atom_key, value)}}
          end

        :error ->
          {:halt, {:error, {:route_assembly_failed, :invalid_profile}}}
      end
    end)
  end

  defp canonical_profile_key(key) when is_atom(key) and key in @profile_keys, do: {:ok, key}

  defp canonical_profile_key(key) when is_binary(key) do
    Enum.find_value(@profile_keys, :error, fn atom ->
      if Atom.to_string(atom) == key, do: {:ok, atom}
    end)
  end

  defp canonical_profile_key(_), do: :error

  defp decision_time(opts) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    case clock.() do
      %DateTime{} = dt -> {:ok, dt}
      _ -> {:error, {:route_assembly_failed, :malformed}}
    end
  rescue
    _ -> {:error, {:route_assembly_failed, :malformed}}
  catch
    _, _ -> {:error, {:route_assembly_failed, :malformed}}
  end

  defp resolve_task_class(opts, profile) do
    case Keyword.fetch(opts, :task_class) do
      {:ok, value} when not is_nil(value) and not is_binary(value) ->
        {:error, {:route_assembly_failed, :invalid_task_class}}

      {:ok, value} when is_binary(value) ->
        map_task_class(ProviderRouter.admit_task_class(value))

      _ ->
        default = Map.get(profile, :default_task_class, "default")
        map_task_class(ProviderRouter.admit_task_class(default))
    end
  end

  defp map_task_class({:ok, task_class}), do: {:ok, task_class}
  defp map_task_class({:error, _}), do: {:error, {:route_assembly_failed, :invalid_profile}}

  # Enabled profiles must admit a task_registry with a "default" entry during
  # assembly — never defer missing/malformed registry shape to Dispatch.
  # Structural validation is owned by ProviderRouter.admit_task_registry/1.
  defp resolve_task_registry(profile) do
    case Map.fetch(profile, :task_registry) do
      {:ok, registry} ->
        case ProviderRouter.admit_task_registry(registry) do
          {:ok, normalized} -> {:ok, normalized}
          {:error, _} -> {:error, {:route_assembly_failed, :invalid_profile}}
        end

      :error ->
        {:error, {:route_assembly_failed, :invalid_profile}}
    end
  end

  # Exactly one catalog source. Production Application config uses
  # catalog_model_ids only. Direct ModelEntry catalog structs are admitted
  # only through the injected test-profile seam.
  defp resolve_catalog(profile, opts, test_profile_seam?) do
    has_catalog? = Map.has_key?(profile, :catalog)
    has_ids? = Map.has_key?(profile, :catalog_model_ids)

    case {has_catalog?, has_ids?, test_profile_seam?} do
      {true, true, _} ->
        {:error, {:route_assembly_failed, :invalid_catalog}}

      {false, false, _} ->
        {:error, {:route_assembly_failed, :invalid_catalog}}

      {true, false, false} ->
        {:error, {:route_assembly_failed, :invalid_catalog}}

      {true, false, true} ->
        resolve_direct_catalog(Map.get(profile, :catalog))

      {false, true, _} ->
        ids = Map.get(profile, :catalog_model_ids)

        with {:ok, ids} <- validate_model_ids(ids),
             {:ok, catalog} <- read_catalog(ids, opts) do
          if catalog == [] do
            {:error, {:route_assembly_failed, :invalid_catalog}}
          else
            {:ok, catalog}
          end
        end
    end
  end

  defp resolve_direct_catalog(catalog) do
    # Full ModelEntry contract admission is owned by ProviderRouter — do not
    # reimplement catalog rules here. Empty / malformed structs fail before Dispatch.
    case ProviderRouter.admit_catalog(catalog) do
      {:ok, admitted} -> {:ok, admitted}
      {:error, _} -> {:error, {:route_assembly_failed, :invalid_catalog}}
    end
  end

  defp validate_model_ids(ids) when is_list(ids) and length(ids) <= @max_catalog do
    if ids == [] do
      {:error, {:route_assembly_failed, :invalid_catalog}}
    else
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
        case ProviderRouter.admit_identifier(id, :catalog_model_id) do
          {:ok, nil} ->
            {:halt, {:error, {:route_assembly_failed, :invalid_catalog}}}

          {:ok, normalized} ->
            if normalized in acc do
              {:halt, {:error, {:route_assembly_failed, :invalid_catalog}}}
            else
              {:cont, {:ok, [normalized | acc]}}
            end

          {:error, _} ->
            {:halt, {:error, {:route_assembly_failed, :invalid_catalog}}}
        end
      end)
      |> case do
        {:ok, list} -> {:ok, Enum.reverse(list)}
        error -> error
      end
    end
  end

  defp validate_model_ids(_), do: {:error, {:route_assembly_failed, :invalid_catalog}}

  defp read_catalog(ids, opts) do
    reader = Keyword.get(opts, :catalog_reader, &default_catalog_reader/1)

    case reader.(ids) do
      {:ok, catalog} ->
        # Reuse ProviderRouter catalog admission (no duplicated ModelEntry rules).
        # Then require exact unique correspondence of canonical_id → requested ids.
        case ProviderRouter.admit_catalog(catalog) do
          {:ok, admitted} -> match_catalog_to_requested_ids(admitted, ids)
          {:error, _} -> {:error, {:route_assembly_failed, :invalid_catalog}}
        end

      {:error, _} ->
        {:error, {:route_assembly_failed, :invalid_catalog}}

      _ ->
        {:error, {:route_assembly_failed, :invalid_catalog}}
    end
  rescue
    _ -> {:error, {:route_assembly_failed, :invalid_catalog}}
  catch
    _, _ -> {:error, {:route_assembly_failed, :invalid_catalog}}
  end

  # Reader catalogs must map 1:1 onto requested model ids by canonical_id:
  # equal count alone is insufficient (wrong id or duplicate ids fail closed).
  defp match_catalog_to_requested_ids(admitted, ids) do
    canonical_ids = Enum.map(admitted, & &1.canonical_id)

    cond do
      length(canonical_ids) != length(ids) ->
        {:error, {:route_assembly_failed, :invalid_catalog}}

      length(Enum.uniq(canonical_ids)) != length(canonical_ids) ->
        {:error, {:route_assembly_failed, :invalid_catalog}}

      MapSet.new(canonical_ids) != MapSet.new(ids) ->
        {:error, {:route_assembly_failed, :invalid_catalog}}

      true ->
        {:ok, admitted}
    end
  end

  defp default_catalog_reader(ids) do
    RouteCatalog.entries(ids)
  end

  # Enabled profiles must declare scoreboard explicitly. An empty list is a
  # valid admission (no ranked evidence yet); a missing key is incomplete.
  defp resolve_scoreboard(profile) do
    case Map.fetch(profile, :scoreboard) do
      {:ok, scoreboard} ->
        case ProviderRouter.admit_scoreboard(scoreboard) do
          {:ok, rows} -> {:ok, rows}
          {:error, _} -> {:error, {:route_assembly_failed, :invalid_scoreboard}}
        end

      :error ->
        {:error, {:route_assembly_failed, :invalid_profile}}
    end
  end

  defp resolve_providers(profile, catalog) do
    explicit = Map.get(profile, :providers, [])

    with {:ok, explicit_names} <- normalize_explicit_providers(explicit) do
      from_catalog =
        for %ModelEntry{providers: providers} <- catalog,
            is_list(providers),
            provider <- providers,
            into: [] do
          Atom.to_string(provider.id)
        end

      names = Enum.uniq(explicit_names ++ from_catalog)

      cond do
        names == [] -> {:error, {:route_assembly_failed, :invalid_profile}}
        length(names) > @max_providers -> {:error, {:route_assembly_failed, :invalid_profile}}
        true -> {:ok, names}
      end
    end
  end

  defp normalize_explicit_providers(explicit) when is_list(explicit) do
    if length(explicit) > @max_providers do
      {:error, {:route_assembly_failed, :invalid_profile}}
    else
      Enum.reduce_while(explicit, {:ok, []}, fn name, {:ok, acc} ->
        case ProviderRouter.admit_identifier(name, :provider) do
          {:ok, nil} ->
            {:halt, {:error, {:route_assembly_failed, :invalid_profile}}}

          {:ok, normalized} ->
            {:cont, {:ok, [normalized | acc]}}

          {:error, _} ->
            {:halt, {:error, {:route_assembly_failed, :invalid_profile}}}
        end
      end)
      |> case do
        {:ok, names} -> {:ok, Enum.reverse(names)}
        error -> error
      end
    end
  end

  defp normalize_explicit_providers(_), do: {:error, {:route_assembly_failed, :invalid_profile}}

  # Injected observation_reader.(providers, decision_time) is exact two-arity and
  # bypasses catalog snapshot / oauth health wiring. Default path is catalog-aware.
  defp resolve_observations(providers, decision_time, catalog, opts) do
    result =
      case Keyword.fetch(opts, :observation_reader) do
        {:ok, reader} when is_function(reader, 2) ->
          reader.(providers, decision_time)

        :error ->
          default_observation_reader(providers, decision_time, catalog, opts)

        {:ok, _} ->
          {:error, :invalid_observation}
      end

    case result do
      {:ok, observations}
      when is_list(observations) and length(observations) <= @max_observations ->
        normalize_observation_list(observations)

      {:ok, _too_many} ->
        {:error, {:route_assembly_failed, :invalid_observation}}

      {:error, :route_failure_evidence_unavailable} ->
        {:error, {:route_assembly_failed, :route_failure_evidence_unavailable}}

      {:error, :route_failure_evidence_malformed} ->
        {:error, {:route_assembly_failed, :route_failure_evidence_malformed}}

      {:error, :quota_evidence_unavailable} ->
        {:error, {:route_assembly_failed, :quota_evidence_unavailable}}

      {:error, :quota_evidence_malformed} ->
        {:error, {:route_assembly_failed, :quota_evidence_malformed}}

      {:error, :route_concurrency_evidence_unavailable} ->
        {:error, {:route_assembly_failed, :route_concurrency_evidence_unavailable}}

      {:error, :route_concurrency_evidence_malformed} ->
        {:error, {:route_assembly_failed, :route_concurrency_evidence_malformed}}

      {:error, :oauth_model_catalog_evidence_unavailable} ->
        {:error, {:route_assembly_failed, :oauth_model_catalog_evidence_unavailable}}

      {:error, :oauth_model_catalog_evidence_malformed} ->
        {:error, {:route_assembly_failed, :oauth_model_catalog_evidence_malformed}}

      {:error, :invalid_observation} ->
        {:error, {:route_assembly_failed, :invalid_observation}}

      {:error, _} ->
        {:error, {:route_assembly_failed, :invalid_observation}}

      _ ->
        {:error, {:route_assembly_failed, :invalid_observation}}
    end
  rescue
    _ -> {:error, {:route_assembly_failed, :invalid_observation}}
  catch
    _, _ -> {:error, {:route_assembly_failed, :invalid_observation}}
  end

  defp normalize_observation_list(observations) do
    Enum.reduce_while(observations, {:ok, []}, fn item, {:ok, acc} ->
      case to_observation_struct(item) do
        {:ok, observation} -> {:cont, {:ok, [observation | acc]}}
        {:error, reason} -> {:halt, {:error, {:route_assembly_failed, reason}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  # Preserve source-owned observed_at/expires_at exactly; never restamp.
  defp to_observation_struct(%ProviderObservation{} = observation) do
    if ProviderObservation.valid?(observation) do
      {:ok, observation}
    else
      {:error, :invalid_observation}
    end
  end

  defp to_observation_struct(%{"observation" => attrs}) when is_map(attrs) do
    to_observation_struct(attrs)
  end

  defp to_observation_struct(%{observation: attrs}) when is_map(attrs) do
    to_observation_struct(attrs)
  end

  defp to_observation_struct(attrs) when is_map(attrs) do
    case ProviderObservation.new(attrs) do
      {:ok, observation} ->
        with :ok <- same_timestamp(attrs, observation, :observed_at, "observed_at"),
             :ok <- same_timestamp(attrs, observation, :expires_at, "expires_at") do
          {:ok, observation}
        else
          _ -> {:error, :invalid_observation}
        end

      _ ->
        {:error, :invalid_observation}
    end
  end

  defp to_observation_struct(_), do: {:error, :invalid_observation}

  defp same_timestamp(attrs, struct, atom_key, string_key) do
    source = Map.get(attrs, atom_key) || Map.get(attrs, string_key)

    cond do
      is_nil(source) -> :ok
      source == Map.get(struct, atom_key) -> :ok
      true -> :error
    end
  end

  defp default_observation_reader(providers, decision_time, catalog, opts) do
    with {:ok, route_failures} <- read_route_failures(decision_time),
         {:ok, quota_status} <- read_quota_evidence(decision_time),
         {:ok, concurrency_snap} <- read_concurrency_snapshot() do
      # Exact OAuth candidates first — only then read catalog snapshot evidence.
      # Zero candidates: skip the irrelevant reader. Non-empty: one bounded
      # snapshot, fail-closed on unavailable/malformed.
      candidates = oauth_route_candidates(catalog)
      non_oauth_providers = Enum.reject(providers, &OAuthHealthObservation.oauth_route?/1)
      planned = length(candidates) + length(non_oauth_providers)

      if planned > @max_observations do
        {:error, :invalid_observation}
      else
        with {:ok, catalog_snap} <- maybe_read_oauth_catalog_snapshot(candidates, opts) do
          health_reader = Keyword.get(opts, :oauth_health_reader, &Arbor.LLM.oauth_health/1)

          emit_default_observations(
            candidates,
            non_oauth_providers,
            catalog_snap,
            health_reader,
            route_failures,
            quota_status,
            concurrency_snap,
            decision_time
          )
        end
      end
    end
  end

  defp emit_default_observations(
         candidates,
         non_oauth_providers,
         catalog_snap,
         health_reader,
         route_failures,
         quota_status,
         concurrency_snap,
         decision_time
       ) do
    oauth_result =
      Enum.reduce_while(candidates, {:ok, {[], %{}}}, fn candidate, {:ok, {acc, health_cache}} ->
        case emit_oauth_candidate(
               candidate,
               catalog_snap,
               health_reader,
               health_cache,
               route_failures,
               quota_status,
               concurrency_snap,
               decision_time
             ) do
          {:ok, attrs, new_cache} ->
            {:cont, {:ok, {[attrs | acc], new_cache}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case oauth_result do
      {:error, reason} ->
        {:error, reason}

      {:ok, {oauth_attrs, _health_cache}} ->
        Enum.reduce_while(non_oauth_providers, {:ok, oauth_attrs}, fn provider, {:ok, acc} ->
          with {:ok, provider_key} <- provider_key(provider),
               {:ok, base} <- non_oauth_base_observation(provider, decision_time) do
            failure = Map.get(route_failures, provider_key)
            quota = Map.get(quota_status, provider_key)

            attrs =
              base
              |> RouteEvidenceOverlay.overlay(failure, quota, decision_time)
              |> overlay_route_concurrency(concurrency_snap)

            {:cont, {:ok, [attrs | acc]}}
          else
            :error -> {:halt, {:error, :invalid_observation}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          error -> error
        end
    end
  end

  defp emit_oauth_candidate(
         candidate,
         catalog_snap,
         health_reader,
         health_cache,
         route_failures,
         quota_status,
         concurrency_snap,
         decision_time
       ) do
    with {:ok, health, new_cache} <-
           health_cached(candidate.provider, health_reader, health_cache),
         {:ok, base} <-
           oauth_candidate_base(candidate, health, catalog_snap, decision_time) do
      failure = Map.get(route_failures, candidate.provider)
      quota = Map.get(quota_status, candidate.provider)

      attrs =
        base
        |> RouteEvidenceOverlay.overlay(failure, quota, decision_time)
        |> overlay_route_concurrency(concurrency_snap)

      {:ok, attrs, new_cache}
    end
  end

  # Arbor OAuth: compose catalog membership. Non-arbor: exact runtime + unknown
  # membership without borrowing catalog evidence (never relabel as arbor).
  defp oauth_candidate_base(candidate, health, catalog_snap, decision_time) do
    if candidate.runtime_atom == :arbor do
      catalog_or_nil = Map.get(catalog_snap, candidate.provider)

      ProviderModelCatalogObservation.compose(
        health,
        catalog_or_nil,
        candidate.ref,
        decision_time
      )
    else
      non_arbor_oauth_observation(candidate, health, decision_time)
    end
  end

  defp non_arbor_oauth_observation(candidate, health, decision_time) do
    case OAuthHealthObservation.from_health(health, decision_time) do
      {:ok, base} when is_map(base) ->
        attrs =
          base
          |> Map.put("provider", candidate.provider)
          |> Map.put("requested_model_id", candidate.ref)
          |> Map.put("runtime", candidate.runtime)
          |> Map.put("model_catalog_membership", "unknown")
          |> Map.put("source", "arbor_oauth_health")

        case ProviderObservation.new(attrs) do
          {:ok, observation} ->
            case ProviderObservation.to_map(observation) do
              map when is_map(map) -> {:ok, map}
              _ -> {:error, :invalid_observation}
            end

          {:error, _} ->
            {:error, :invalid_observation}
        end

      _ ->
        {:error, :invalid_observation}
    end
  rescue
    _ -> {:error, :invalid_observation}
  catch
    _, _ -> {:error, :invalid_observation}
  end

  # Exact OAuth ProviderEntry×runtime candidates from admitted ModelEntry catalog.
  # requested_model_id uses ProviderEntry.ref with no alias coercion.
  defp oauth_route_candidates(catalog) when is_list(catalog) do
    candidates =
      for %ModelEntry{providers: providers} <- catalog,
          is_list(providers),
          %ProviderEntry{} = pe <- providers,
          OAuthHealthObservation.oauth_route?(pe.id),
          runtime <- pe.runtimes,
          is_atom(runtime) do
        %{
          provider: Atom.to_string(pe.id),
          ref: pe.ref,
          runtime_atom: runtime,
          runtime: Atom.to_string(runtime)
        }
      end

    Enum.uniq_by(candidates, &{&1.provider, &1.ref, &1.runtime})
  end

  defp oauth_route_candidates(_), do: []

  defp canonical_oauth_route_order(routes) do
    Enum.filter(["openai_oauth", "xai_oauth"], &(&1 in routes))
  end

  defp health_cached(route, reader, cache) when is_map(cache) do
    case Map.fetch(cache, route) do
      {:ok, health} ->
        {:ok, health, cache}

      :error ->
        case reader.(route) do
          {:ok, health} -> {:ok, health, Map.put(cache, route, health)}
          {:error, _} -> {:error, :invalid_observation}
          _ -> {:error, :invalid_observation}
        end
    end
  rescue
    _ -> {:error, :invalid_observation}
  catch
    _, _ -> {:error, :invalid_observation}
  end

  # Skip the OAuth catalog snapshot when no exact OAuth candidates exist.
  # Empty map is a safe no-op for emit paths that never consult it.
  defp maybe_read_oauth_catalog_snapshot([], _opts), do: {:ok, %{}}

  defp maybe_read_oauth_catalog_snapshot(_candidates, opts),
    do: read_and_admit_oauth_catalog_snapshot(opts)

  # One bounded OAuth catalog snapshot per default assembly when OAuth
  # candidates exist; shape-admit before use. Fail closed on unavailable/malformed.
  defp read_and_admit_oauth_catalog_snapshot(opts) do
    reader =
      Keyword.get(opts, :oauth_catalog_snapshot_reader, fn ->
        Arbor.AI.oauth_model_catalog_snapshot([])
      end)

    case reader.() do
      {:ok, snap} when is_map(snap) ->
        admit_oauth_catalog_snapshot(snap)

      {:error, :unavailable} ->
        {:error, :oauth_model_catalog_evidence_unavailable}

      {:error, :malformed} ->
        {:error, :oauth_model_catalog_evidence_malformed}

      _ ->
        {:error, :oauth_model_catalog_evidence_malformed}
    end
  rescue
    _ -> {:error, :oauth_model_catalog_evidence_malformed}
  catch
    _, _ -> {:error, :oauth_model_catalog_evidence_malformed}
  end

  defp admit_oauth_catalog_snapshot(snap) when is_map(snap) do
    cond do
      map_size(snap) == 0 ->
        {:ok, %{}}

      map_size(snap) > @max_oauth_catalog_routes ->
        {:error, :oauth_model_catalog_evidence_malformed}

      true ->
        Enum.reduce_while(snap, {:ok, %{}}, fn {route, entry}, {:ok, acc} ->
          cond do
            not exact_oauth_route_string?(route) ->
              {:halt, {:error, :oauth_model_catalog_evidence_malformed}}

            is_nil(entry) ->
              {:halt, {:error, :oauth_model_catalog_evidence_malformed}}

            true ->
              case ProviderModelCatalog.new(entry) do
                {:ok, %ProviderModelCatalog{route: catalog_route} = valid} ->
                  if catalog_route == route do
                    {:cont, {:ok, Map.put(acc, route, valid)}}
                  else
                    {:halt, {:error, :oauth_model_catalog_evidence_malformed}}
                  end

                {:error, _} ->
                  {:halt, {:error, :oauth_model_catalog_evidence_malformed}}
              end
          end
        end)
    end
  end

  defp admit_oauth_catalog_snapshot(_), do: {:error, :oauth_model_catalog_evidence_malformed}

  defp exact_oauth_route_string?(route) when is_binary(route),
    do: MapSet.member?(@oauth_catalog_routes, route)

  defp exact_oauth_route_string?(_), do: false

  # One bounded node-local snapshot per assembly; fail closed when unavailable.
  defp read_concurrency_snapshot do
    case RouteConcurrency.snapshot() do
      {:ok, snap} when is_map(snap) ->
        case RouteConcurrencyCore.validate_snapshot(snap) do
          {:ok, validated} -> {:ok, validated}
          {:error, :malformed} -> {:error, :route_concurrency_evidence_malformed}
        end

      {:error, :unavailable} ->
        {:error, :route_concurrency_evidence_unavailable}

      {:error, :malformed} ->
        {:error, :route_concurrency_evidence_malformed}

      _ ->
        {:error, :route_concurrency_evidence_malformed}
    end
  end

  defp overlay_route_concurrency(attrs, snap) when is_map(attrs) and is_map(snap) do
    provider = Map.get(attrs, :provider) || Map.get(attrs, "provider")
    runtime = Map.get(attrs, :runtime) || Map.get(attrs, "runtime")

    entry =
      case RouteConcurrencyCore.normalize_route(provider, runtime) do
        {:ok, route_key} -> Map.get(snap, route_key)
        {:error, :malformed_route} -> nil
      end

    RouteEvidenceOverlay.overlay_concurrency(attrs, entry)
  end

  defp overlay_route_concurrency(attrs, _snap), do: attrs

  # Non-OAuth readiness only — OAuth rows come from admitted ModelEntry candidates.
  defp non_oauth_base_observation(provider, decision_time) do
    envelope =
      Arbor.AI.AcpSession.Readiness.Internal.observe(provider, nil,
        clock: fn -> decision_time end
      )

    case envelope do
      %{"observation" => attrs} when is_map(attrs) -> {:ok, attrs}
      _ -> {:error, :invalid_observation}
    end
  end

  defp read_route_failures(decision_time) do
    case Arbor.AI.provider_route_failure_evidence_snapshot(now: decision_time) do
      {:ok, failures} when is_map(failures) ->
        {:ok, failures}

      {:error, :unavailable} ->
        {:error, :route_failure_evidence_unavailable}

      {:error, :malformed} ->
        {:error, :route_failure_evidence_malformed}

      _ ->
        {:error, :route_failure_evidence_malformed}
    end
  end

  defp read_quota_evidence(decision_time) do
    case Arbor.AI.provider_route_quota_evidence_snapshot(now: decision_time) do
      {:ok, quota} when is_map(quota) -> {:ok, quota}
      {:error, :unavailable} -> {:error, :quota_evidence_unavailable}
      {:error, :malformed} -> {:error, :quota_evidence_malformed}
      _ -> {:error, :quota_evidence_malformed}
    end
  end

  # Exact route identities only — never coerce via to_string/1.
  defp provider_key(provider) when is_binary(provider), do: {:ok, provider}
  defp provider_key(provider) when is_atom(provider), do: {:ok, Atom.to_string(provider)}
  defp provider_key(_), do: :error

  defp resolve_budgets(providers, decision_time, opts) do
    reader = Keyword.get(opts, :budget_reader, &default_budget_reader/2)

    case reader.(providers, decision_time) do
      {:ok, budgets} when is_list(budgets) and length(budgets) <= @max_budgets ->
        normalize_budget_list(budgets, providers)

      {:ok, _too_many} ->
        {:error, {:route_assembly_failed, :invalid_budget}}

      {:error, :missing_budget} ->
        {:error, {:route_assembly_failed, :missing_budget}}

      {:error, :invalid_budget} ->
        {:error, {:route_assembly_failed, :invalid_budget}}

      {:error, _} ->
        {:error, {:route_assembly_failed, :invalid_budget}}

      _ ->
        {:error, {:route_assembly_failed, :invalid_budget}}
    end
  rescue
    _ -> {:error, {:route_assembly_failed, :invalid_budget}}
  catch
    _, _ -> {:error, {:route_assembly_failed, :invalid_budget}}
  end

  defp normalize_budget_list(budgets, providers) do
    with {:ok, structs} <-
           Enum.reduce_while(budgets, {:ok, []}, fn item, {:ok, acc} ->
             case to_budget_struct(item) do
               {:ok, snapshot} -> {:cont, {:ok, [snapshot | acc]}}
               {:error, reason} -> {:halt, {:error, {:route_assembly_failed, reason}}}
             end
           end) do
      structs = Enum.reverse(structs)
      covered = MapSet.new(Enum.map(structs, & &1.provider))

      if Enum.all?(providers, &MapSet.member?(covered, &1)) do
        {:ok, structs}
      else
        {:error, {:route_assembly_failed, :missing_budget}}
      end
    end
  end

  defp to_budget_struct(%BudgetSnapshot{} = snapshot) do
    if BudgetSnapshot.valid?(snapshot), do: {:ok, snapshot}, else: {:error, :invalid_budget}
  end

  defp to_budget_struct(%{"snapshot" => attrs}) when is_map(attrs), do: to_budget_struct(attrs)
  defp to_budget_struct(%{snapshot: attrs}) when is_map(attrs), do: to_budget_struct(attrs)

  defp to_budget_struct(attrs) when is_map(attrs) do
    case BudgetSnapshot.new(attrs) do
      {:ok, snapshot} ->
        with :ok <- same_timestamp(attrs, snapshot, :observed_at, "observed_at"),
             :ok <- same_timestamp(attrs, snapshot, :expires_at, "expires_at") do
          {:ok, snapshot}
        else
          _ -> {:error, :invalid_budget}
        end

      _ ->
        {:error, :invalid_budget}
    end
  end

  defp to_budget_struct(_), do: {:error, :invalid_budget}

  defp default_budget_reader(providers, decision_time) do
    Enum.reduce_while(providers, {:ok, []}, fn provider, {:ok, acc} ->
      case ProviderControlPlane.snapshot(provider, observed_at: decision_time) do
        {:ok, %{snapshot: snapshot}} ->
          case to_budget_struct(snapshot) do
            {:ok, struct} -> {:cont, {:ok, [struct | acc]}}
            {:error, _} -> {:halt, {:error, :invalid_budget}}
          end

        {:error, :unavailable} ->
          {:halt, {:error, :missing_budget}}

        {:error, _} ->
          {:halt, {:error, :invalid_budget}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp build_policy(profile) do
    fallback_limit = Map.get(profile, :fallback_limit, @max_fallbacks)
    params = Map.get(profile, :params, %{})

    fallback_ok? =
      is_integer(fallback_limit) and fallback_limit >= 0 and
        fallback_limit <= @max_fallbacks

    cond do
      not is_map(params) or is_struct(params) or map_size(params) != 0 ->
        {:error, {:route_assembly_failed, :invalid_profile}}

      not fallback_ok? ->
        {:error, {:route_assembly_failed, :invalid_profile}}

      true ->
        {:ok, %{strict_evidence: true, fallback_limit: fallback_limit, params: %{}}}
    end
  end
end
