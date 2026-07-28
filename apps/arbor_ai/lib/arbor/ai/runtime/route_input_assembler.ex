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

  Injectable `profile`/`clock`/readers are a **test seam only**. Production
  callers use `Arbor.AI.assemble_provider_route_input/1`, which loads the
  reviewed Application profile and production readers.
  """

  alias Arbor.AI.ProviderControlPlane
  alias Arbor.AI.Runtime.ProviderRouter
  alias Arbor.Common.ModelProfile
  alias Arbor.Contracts.LLM.BudgetSnapshot
  alias Arbor.Contracts.LLM.ModelEntry
  alias Arbor.Contracts.LLM.ProviderObservation

  @max_catalog 128
  @max_providers 128
  @max_observations 256
  @max_budgets 256
  @max_fallbacks 64
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
         {:ok, observations} <- resolve_observations(providers, decision_time, opts),
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
    catalog = Enum.map(ids, &ModelProfile.entry/1)
    {:ok, catalog}
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

  defp resolve_observations(providers, decision_time, opts) do
    reader = Keyword.get(opts, :observation_reader, &default_observation_reader/2)

    case reader.(providers, decision_time) do
      {:ok, observations}
      when is_list(observations) and length(observations) <= @max_observations ->
        normalize_observation_list(observations)

      {:ok, _too_many} ->
        {:error, {:route_assembly_failed, :invalid_observation}}

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

  defp default_observation_reader(providers, decision_time) do
    observations =
      Enum.map(providers, fn provider ->
        envelope =
          Arbor.AI.AcpSession.Readiness.Internal.observe(provider, nil,
            clock: fn -> decision_time end
          )

        case envelope do
          %{"observation" => attrs} when is_map(attrs) -> attrs
          _ -> :error
        end
      end)

    if Enum.any?(observations, &(&1 == :error)) do
      {:error, :invalid_observation}
    else
      {:ok, observations}
    end
  end

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
