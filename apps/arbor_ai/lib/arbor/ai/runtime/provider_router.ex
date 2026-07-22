defmodule Arbor.AI.Runtime.ProviderRouter do
  @moduledoc """
  Pure, data-in/data-out provider route decision core.

  `decide_route/1` consumes an assembled task registry, model catalog,
  scoreboard, readiness observations, and budget snapshots. It does not read
  application state, the clock, or a provider registry. `Selector.choose/2`
  remains the compatibility API for the current runtime path. Evidence from
  multiple accounts for one provider is rejected rather than merged; callers
  must assemble an unambiguous account-scoped input.
  """

  alias Arbor.Contracts.LLM.{BudgetSnapshot, ModelEntry, ProviderEntry, ProviderObservation}

  @max_task_class_bytes 256
  @max_segment_bytes 64
  @max_registry_entries 128
  @max_catalog_entries 128
  @max_scoreboard_rows 512
  @max_observations 256
  @max_budgets 256
  @max_candidates 512
  @max_fallbacks 64
  @max_map_entries 64
  @max_text_bytes 512
  @max_number 1.0e18
  @max_json_depth 8
  @max_json_nodes 256

  @input_keys ~w(task_class task_registry requirements catalog scoreboard observations budgets now policy)a
  @policy_keys ~w(strict_evidence fallback_limit params)a
  @requirement_keys ~w(
    min_context min_context_window capabilities required_capabilities needs
    max_latency_ms max_cost max_format_failure_rate max_dangerous_misses
    runtime runtimes allowed_runtimes provider providers allowed_providers
    model model_id requested_model_id exact_model requested_model
    exact_model_binding
  )a
  @scoreboard_keys ~w(
    task_class model provider runtime score dangerous_misses format_failure_rate
    variance marginal_cost latency_ms tok_per_s last_verified eval_run_ref quant hardware
  )a
  @scoreboard_aliases %{
    "model_id" => :model,
    "canonical_id" => :model,
    "dangerous_miss_count" => :dangerous_misses,
    "format_failures" => :format_failure_rate,
    "cost" => :marginal_cost,
    "latency" => :latency_ms,
    "throughput" => :tok_per_s
  }

  @type input :: %{
          required(:task_class) => String.t(),
          optional(:task_registry) => map(),
          optional(:requirements) => map(),
          required(:catalog) => [ModelEntry.t()],
          required(:scoreboard) => [map()],
          required(:observations) => [ProviderObservation.t()],
          required(:budgets) => [BudgetSnapshot.t()],
          required(:now) => DateTime.t() | String.t(),
          optional(:policy) => map()
        }

  @doc """
  Decide the primary model route and its ordered fallback chain.

  Success is `{:ok, json_clean_decision}`. Malformed assembled data and an
  empty eligible set return an explicit error. All time-dependent decisions
  use the supplied `:now` value.
  """
  @spec decide_route(input() | keyword()) :: {:ok, map()} | {:error, term()}
  def decide_route(input) do
    with {:ok, input} <- normalize_input(input),
         {:ok, now} <- normalize_now(input.now),
         {:ok, registry} <- normalize_registry(input[:task_registry], input[:requirements]),
         {:ok, class} <- resolve_task_class(input.task_class, registry),
         {:ok, requirements} <- normalize_requirements(class.requirements),
         {:ok, catalog} <- validate_catalog(input.catalog),
         {:ok, scoreboard} <- validate_scoreboard(input.scoreboard),
         {:ok, observations} <- validate_observations(input.observations),
         {:ok, budgets} <- validate_budgets(input.budgets),
         {:ok, policy} <- normalize_policy(input[:policy] || %{}),
         {:ok, candidates} <- build_candidates(catalog),
         {:ok, decision} <-
           evaluate_candidates(
             candidates,
             requirements,
             class,
             now,
             policy,
             scoreboard,
             observations,
             budgets
           ) do
      {:ok, decision}
    end
  rescue
    _ -> {:error, {:invalid_route_input, :malformed}}
  catch
    _, _ -> {:error, {:invalid_route_input, :malformed}}
  end

  @doc "Alias for callers that prefer the shorter pure-router name."
  @spec route(input() | keyword()) :: {:ok, map()} | {:error, term()}
  def route(input), do: decide_route(input)

  defp normalize_input(input) when is_list(input) do
    with {:ok, input} <- canonical_keyword_fields(input, @input_keys, :invalid_route_input),
         do: normalize_input(input)
  end

  defp normalize_input(input) when is_map(input) and not is_struct(input) do
    if map_size(input) > @max_map_entries do
      {:error, {:invalid_route_input, :object_too_large}}
    else
      with {:ok, values} <- canonical_fields(input, @input_keys, :invalid_route_input),
           :ok <- require_field(values, :task_class),
           :ok <- require_field(values, :catalog),
           :ok <- require_field(values, :scoreboard),
           :ok <- require_field(values, :observations),
           :ok <- require_field(values, :budgets),
           :ok <- require_field(values, :now),
           :ok <- require_registry_or_requirements(values) do
        {:ok, values}
      end
    end
  end

  defp normalize_input(_input), do: {:error, {:invalid_route_input, :object_required}}

  defp canonical_fields(map, allowed, tag) do
    Enum.reduce_while(Map.to_list(map), {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, field} <- canonical_key(key, allowed),
           :ok <- duplicate_free(acc, field, tag) do
        {:cont, {:ok, Map.put(acc, field, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp canonical_keyword_fields(values, allowed, tag) do
    if bounded_list?(values, @max_map_entries) do
      Enum.reduce_while(values, {:ok, %{}}, fn
        {key, value}, {:ok, acc} ->
          with {:ok, field} <- canonical_key(key, allowed),
               :ok <- duplicate_free(acc, field, tag) do
            {:cont, {:ok, Map.put(acc, field, value)}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _entry, _acc ->
          {:halt, {:error, {:invalid_route_input, :invalid_keyword}}}
      end)
    else
      {:error, {:invalid_route_input, {:too_many, tag}}}
    end
  end

  defp canonical_key(key, allowed) when is_atom(key) do
    if key in allowed,
      do: {:ok, key},
      else: {:error, {:invalid_route_input, {:unknown_field, key}}}
  end

  defp canonical_key(key, allowed) when is_binary(key) do
    case Enum.find(allowed, fn atom -> Atom.to_string(atom) == key end) do
      nil -> {:error, {:invalid_route_input, {:unknown_field, key}}}
      field -> {:ok, field}
    end
  end

  defp canonical_key(_key, _allowed), do: {:error, {:invalid_route_input, :invalid_key}}

  defp duplicate_free(map, key, tag) do
    if Map.has_key?(map, key), do: {:error, {tag, {:duplicate_field, key}}}, else: :ok
  end

  defp require_field(map, key) do
    if Map.has_key?(map, key), do: :ok, else: {:error, {:invalid_route_input, {:missing, key}}}
  end

  defp require_registry_or_requirements(map) do
    if Map.has_key?(map, :task_registry) or Map.has_key?(map, :requirements),
      do: :ok,
      else: {:error, {:invalid_route_input, {:missing, :task_registry}}}
  end

  defp normalize_now(%DateTime{} = now), do: {:ok, now}

  defp normalize_now(now) when is_binary(now) do
    case DateTime.from_iso8601(now) do
      {:ok, datetime, _offset} -> DateTime.shift_zone(datetime, "Etc/UTC")
      _ -> {:error, {:invalid_route_input, :now}}
    end
  end

  defp normalize_now(_now), do: {:error, {:invalid_route_input, :now}}

  defp normalize_registry(nil, requirements) when is_map(requirements),
    do: normalize_registry(%{"default" => requirements}, nil)

  defp normalize_registry(nil, nil),
    do: {:error, {:invalid_route_input, {:missing, :task_registry}}}

  defp normalize_registry(raw, direct_requirements) when is_map(raw) and not is_struct(raw) do
    if map_size(raw) > @max_registry_entries do
      {:error, {:invalid_route_input, {:too_many, :task_registry}}}
    else
      with {:ok, entries} <- normalize_registry_entries(Map.to_list(raw), %{}),
           :ok <- require_field(entries, "default"),
           {:ok, entries} <- maybe_direct_default(entries, direct_requirements) do
        {:ok, entries}
      end
    end
  end

  defp normalize_registry(_raw, _direct),
    do: {:error, {:invalid_route_input, {:invalid, :task_registry}}}

  defp normalize_registry_entries([], acc), do: {:ok, acc}

  defp normalize_registry_entries([{key, value} | rest], acc) do
    with {:ok, key} <- normalize_task_class(key),
         :ok <- duplicate_free(acc, key, :invalid_task_registry),
         {:ok, requirements} <- registry_requirements(value) do
      normalize_registry_entries(rest, Map.put(acc, key, requirements))
    end
  end

  defp normalize_registry_entries(_entries, _acc),
    do: {:error, {:invalid_route_input, {:invalid, :task_registry}}}

  defp maybe_direct_default(entries, nil), do: {:ok, entries}

  defp maybe_direct_default(entries, requirements) when is_map(requirements) do
    with {:ok, requirements} <- registry_requirements(requirements) do
      {:ok, Map.put(entries, "default", requirements)}
    end
  end

  defp maybe_direct_default(_entries, _requirements),
    do: {:error, {:invalid_route_input, {:invalid, :requirements}}}

  defp registry_requirements(%{} = value) when not is_struct(value) do
    case fetch_alias(value, :requirements) do
      {:ok, requirements} when is_map(requirements) and not is_struct(requirements) ->
        {:ok, requirements}

      {:ok, _requirements} ->
        {:error, {:invalid_route_input, {:invalid, :requirements}}}

      :missing ->
        {:ok, value}
    end
  end

  defp registry_requirements(_value),
    do: {:error, {:invalid_route_input, {:invalid, :task_registry_entry}}}

  defp resolve_task_class(task_class, registry) do
    with {:ok, task_class} <- normalize_task_class(task_class) do
      segments = String.split(task_class, ".")

      candidates =
        case segments do
          [_] ->
            []

          _ ->
            Enum.map(
              Range.new(length(segments) - 1, 1, -1),
              &(Enum.take(segments, &1) |> Enum.join("."))
            )
        end

      cond do
        Map.has_key?(registry, task_class) ->
          {:ok,
           %{
             requirements: Map.fetch!(registry, task_class),
             resolved: task_class,
             requested: task_class,
             resolution: "exact",
             unknown: false
           }}

        Enum.find(candidates, &Map.has_key?(registry, &1)) ->
          resolved = Enum.find(candidates, &Map.has_key?(registry, &1))

          {:ok,
           %{
             requirements: Map.fetch!(registry, resolved),
             resolved: resolved,
             requested: task_class,
             resolution: "longest_prefix",
             unknown: false
           }}

        true ->
          {:ok,
           %{
             requirements: Map.fetch!(registry, "default"),
             resolved: "default",
             requested: task_class,
             resolution: "default",
             unknown: task_class != "default"
           }}
      end
    end
  end

  defp normalize_task_class(value) when is_atom(value),
    do: normalize_task_class(Atom.to_string(value))

  defp normalize_task_class(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) > 0 and byte_size(value) <= @max_task_class_bytes and
         String.split(value, ".") |> Enum.all?(&valid_segment?/1),
       do: {:ok, value},
       else: {:error, {:invalid_route_input, {:invalid, :task_class}}}
  end

  defp normalize_task_class(_value), do: {:error, {:invalid_route_input, {:invalid, :task_class}}}

  defp valid_segment?(segment) do
    byte_size(segment) > 0 and byte_size(segment) <= @max_segment_bytes and
      String.valid?(segment) and String.match?(segment, ~r/^[A-Za-z0-9_-]+$/)
  end

  defp normalize_requirements(requirements)
       when is_map(requirements) and not is_struct(requirements) do
    if map_size(requirements) > @max_map_entries do
      {:error, {:invalid_route_input, {:too_many, :requirements}}}
    else
      with {:ok, values} <-
             canonical_alias_fields(requirements, @requirement_keys, :invalid_requirements),
           {:ok, values} <- normalize_requirement_values(values) do
        {:ok, values}
      end
    end
  end

  defp normalize_requirements(_requirements),
    do: {:error, {:invalid_route_input, {:invalid, :requirements}}}

  defp canonical_alias_fields(map, allowed, tag) do
    Enum.reduce_while(Map.to_list(map), {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, field} <- alias_key(key, allowed),
           :ok <- duplicate_free(acc, field, tag) do
        {:cont, {:ok, Map.put(acc, field, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp alias_key(key, allowed) when is_atom(key) do
    alias_key(Atom.to_string(key), allowed)
  end

  defp alias_key(key, allowed) when is_binary(key) do
    aliases = %{
      "min_context_window" => :min_context,
      "required_capabilities" => :capabilities,
      "needs" => :capabilities,
      "runtimes" => :runtimes,
      "allowed_runtimes" => :runtimes,
      "providers" => :providers,
      "allowed_providers" => :providers,
      "model" => :requested_model,
      "model_id" => :requested_model,
      "requested_model_id" => :requested_model,
      "exact_model" => :requested_model
    }

    canonical = Map.get(aliases, key, safe_existing_allowed(key, allowed))

    if canonical in allowed,
      do: {:ok, canonical},
      else: {:error, {:invalid_route_input, {:unknown_requirement, key}}}
  end

  defp alias_key(_key, _allowed), do: {:error, {:invalid_route_input, :invalid_requirement_key}}

  defp safe_existing_allowed(key, allowed) do
    Enum.find(allowed, fn field -> Atom.to_string(field) == key end)
  end

  defp normalize_requirement_values(values) do
    with :ok <- optional_bounded_integer(values, :min_context, 1),
         :ok <- optional_bounded_integer(values, :max_latency_ms, 0),
         :ok <- optional_bounded_number(values, :max_cost, 0, @max_number),
         :ok <- optional_bounded_number(values, :max_format_failure_rate, 0, 1.0),
         :ok <- optional_bounded_integer(values, :max_dangerous_misses, 0),
         :ok <- optional_boolean(values, :exact_model_binding),
         {:ok, capabilities} <- normalize_identifier_list(values[:capabilities], :capabilities),
         {:ok, runtimes} <- normalize_identifier_list(values[:runtimes], :runtimes),
         {:ok, providers} <- normalize_identifier_list(values[:providers], :providers),
         {:ok, runtime} <- optional_identifier(values[:runtime], :runtime),
         {:ok, provider} <- optional_identifier(values[:provider], :provider),
         {:ok, requested_model} <- optional_identifier(values[:requested_model], :requested_model) do
      {:ok,
       values
       |> Map.put_new(:min_context, nil)
       |> Map.put_new(:max_latency_ms, nil)
       |> Map.put_new(:max_cost, nil)
       |> Map.put_new(:max_format_failure_rate, nil)
       |> Map.put_new(:max_dangerous_misses, nil)
       |> Map.put_new(:exact_model_binding, false)
       |> Map.put(:capabilities, capabilities)
       |> Map.put(:runtimes, runtimes)
       |> Map.put(:providers, providers)
       |> Map.put(:runtime, runtime)
       |> Map.put(:provider, provider)
       |> Map.put(:requested_model, requested_model)}
    end
  end

  defp optional_bounded_integer(values, key, minimum) do
    case values[key] do
      nil -> :ok
      value when is_integer(value) and value >= minimum and value <= 1_000_000_000 -> :ok
      _ -> {:error, {:invalid_route_input, {:invalid, key}}}
    end
  end

  defp optional_bounded_number(values, key, minimum, maximum) do
    case values[key] do
      nil ->
        :ok

      value when is_integer(value) and value >= minimum and value <= maximum ->
        :ok

      value when is_float(value) and value == value and value >= minimum and value <= maximum ->
        :ok

      _ ->
        {:error, {:invalid_route_input, {:invalid, key}}}
    end
  end

  defp optional_boolean(values, key) do
    case values[key] do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _ -> {:error, {:invalid_route_input, {:invalid, key}}}
    end
  end

  defp normalize_identifier_list(nil, _field), do: {:ok, nil}

  defp normalize_identifier_list(values, field) when is_list(values) do
    if bounded_list?(values, @max_map_entries) do
      values
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
        case value do
          nil ->
            {:halt, {:error, {:invalid_route_input, {:invalid, field}}}}

          value ->
            case optional_identifier(value, field) do
              {:ok, value} ->
                if value in acc do
                  {:halt, {:error, {:invalid_route_input, {:duplicate, field}}}}
                else
                  {:cont, {:ok, [value | acc]}}
                end

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        error -> error
      end
    else
      {:error, {:invalid_route_input, {:too_many, field}}}
    end
  end

  defp normalize_identifier_list(_values, field),
    do: {:error, {:invalid_route_input, {:invalid, field}}}

  defp optional_identifier(nil, _field), do: {:ok, nil}

  defp optional_identifier(value, field) when is_atom(value),
    do: optional_identifier(Atom.to_string(value), field)

  defp optional_identifier(value, field) when is_binary(value) do
    if String.valid?(value) and byte_size(value) > 0 and byte_size(value) <= @max_text_bytes and
         String.trim(value) == value and not String.match?(value, ~r/[\x00-\x1F\x7F]/),
       do: {:ok, value},
       else: {:error, {:invalid_route_input, {:invalid, field}}}
  end

  defp optional_identifier(_value, field),
    do: {:error, {:invalid_route_input, {:invalid, field}}}

  defp validate_catalog(catalog) when is_list(catalog) do
    if not bounded_list?(catalog, @max_catalog_entries) do
      {:error, {:invalid_route_input, {:too_many, :catalog}}}
    else
      validate_catalog_entries(catalog)
    end
  end

  defp validate_catalog(_catalog), do: {:error, {:invalid_route_input, {:invalid, :catalog}}}

  defp validate_catalog_entries(catalog) do
    if catalog == [] do
      {:error, {:invalid_route_input, {:invalid, :catalog}}}
    else
      Enum.reduce_while(catalog, {:ok, []}, fn entry, {:ok, acc} ->
        case valid_model_entry?(entry) do
          true -> {:cont, {:ok, [entry | acc]}}
          false -> {:halt, {:error, {:invalid_route_input, {:invalid, :catalog_entry}}}}
        end
      end)
      |> reverse_ok()
    end
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error

  defp valid_model_entry?(%ModelEntry{} = entry) do
    with true <- valid_text?(entry.canonical_id, @max_text_bytes),
         true <-
           is_list(entry.providers) and entry.providers != [] and
             bounded_list?(entry.providers, @max_candidates),
         true <- is_atom(entry.family),
         true <- bounded_integer?(entry.context_window, 1),
         true <- bounded_integer?(entry.max_output_tokens, 1),
         true <-
           is_float(entry.effective_window_pct) and entry.effective_window_pct >= 0.0 and
             entry.effective_window_pct <= 1.0,
         true <-
           is_list(entry.capabilities) and bounded_list?(entry.capabilities, @max_map_entries) and
             Enum.all?(entry.capabilities, &is_atom/1),
         true <-
           is_list(entry.caveats) and bounded_list?(entry.caveats, @max_map_entries) and
             Enum.all?(entry.caveats, &valid_text?(&1, @max_text_bytes)),
         true <- Enum.all?(entry.providers, &valid_provider_entry?/1) do
      true
    else
      _ -> false
    end
  end

  defp valid_model_entry?(_entry), do: false

  defp valid_provider_entry?(%ProviderEntry{} = provider) do
    is_atom(provider.id) and valid_text?(provider.ref, @max_text_bytes) and
      provider.auth in [:api_key, :oauth, :aws, :gcp, :none] and
      is_list(provider.runtimes) and provider.runtimes != [] and
      bounded_list?(provider.runtimes, @max_map_entries) and
      Enum.all?(provider.runtimes, &is_atom/1)
  end

  defp valid_provider_entry?(_provider), do: false

  defp valid_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and byte_size(value) > 0 and
      byte_size(value) <= maximum and
      String.trim(value) == value and not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp bounded_integer?(value, minimum),
    do: is_integer(value) and value >= minimum and value <= 1_000_000_000

  defp bounded_list?(value, maximum) when is_list(value),
    do: bounded_list?(value, maximum, maximum)

  defp bounded_list?(_value, _maximum), do: false

  defp bounded_list?([], _maximum, _remaining), do: true

  defp bounded_list?([_head | tail], maximum, remaining) when remaining > 0,
    do: bounded_list?(tail, maximum, remaining - 1)

  defp bounded_list?(_value, _maximum, _remaining), do: false

  defp validate_scoreboard(rows) when is_list(rows) do
    if bounded_list?(rows, @max_scoreboard_rows) do
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
        case normalize_scoreboard_row(row) do
          {:ok, row} -> {:cont, {:ok, [row | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> reverse_ok()
      |> ensure_unique_scoreboard_rows()
    else
      {:error, {:invalid_route_input, {:too_many, :scoreboard}}}
    end
  end

  defp validate_scoreboard(_rows), do: {:error, {:invalid_route_input, {:invalid, :scoreboard}}}

  defp ensure_unique_scoreboard_rows({:ok, rows}) do
    identities = Enum.map(rows, &{&1.task_class, &1.model, &1.provider, &1.runtime})

    if MapSet.size(MapSet.new(identities)) == length(identities),
      do: {:ok, rows},
      else: {:error, {:invalid_route_input, {:duplicate, :scoreboard_row}}}
  end

  defp ensure_unique_scoreboard_rows(error), do: error

  defp normalize_scoreboard_row(row) when is_map(row) and map_size(row) > @max_map_entries,
    do: {:error, {:invalid_route_input, {:too_many, :scoreboard_row}}}

  defp normalize_scoreboard_row(row) when is_map(row) and not is_struct(row) do
    with {:ok, row} <- canonical_scoreboard_fields(row),
         {:ok, model} <-
           optional_identifier(
             row[:model] || row[:model_id] || row[:canonical_id],
             :scoreboard_model
           ),
         true <- not is_nil(model) do
      row = row |> Map.put(:model, model) |> Map.delete(:model_id) |> Map.delete(:canonical_id)

      with {:ok, row} <- normalize_scoreboard_identifiers(row),
           :ok <- validate_scoreboard_metrics(row) do
        {:ok, row}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, {:invalid_route_input, {:invalid, :scoreboard_row}}}
      end
    else
      false -> {:error, {:invalid_route_input, {:missing, :scoreboard_model}}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_route_input, {:invalid, :scoreboard_row}}}
    end
  end

  defp normalize_scoreboard_row(_row),
    do: {:error, {:invalid_route_input, {:invalid, :scoreboard_row}}}

  defp canonical_scoreboard_fields(map) do
    Enum.reduce_while(Map.to_list(map), {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, field} <- scoreboard_key(key),
           :ok <- duplicate_free(acc, field, :invalid_scoreboard) do
        {:cont, {:ok, Map.put(acc, field, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp scoreboard_key(key) when is_atom(key), do: scoreboard_key(Atom.to_string(key))

  defp scoreboard_key(key) when is_binary(key) do
    field =
      Map.get(@scoreboard_aliases, key, Enum.find(@scoreboard_keys, &(Atom.to_string(&1) == key)))

    if field,
      do: {:ok, field},
      else: {:error, {:invalid_route_input, {:unknown_scoreboard_field, key}}}
  end

  defp scoreboard_key(_key), do: {:error, {:invalid_route_input, :invalid_scoreboard_key}}

  defp normalize_scoreboard_identifiers(row) do
    with {:ok, task_class} <- optional_task_class(row[:task_class]),
         {:ok, provider} <- optional_identifier(row[:provider], :scoreboard_provider),
         {:ok, runtime} <- optional_identifier(row[:runtime], :scoreboard_runtime) do
      {:ok,
       row
       |> Map.put(:task_class, task_class)
       |> Map.put(:provider, provider)
       |> Map.put(:runtime, runtime)}
    end
  end

  defp optional_task_class(nil), do: {:ok, nil}
  defp optional_task_class(value), do: normalize_task_class(value)

  defp validate_scoreboard_metrics(row) do
    with :ok <- optional_number(row, :score, -@max_number, @max_number),
         :ok <- optional_nonnegative_integer(row, :dangerous_misses),
         :ok <- optional_nonnegative_number(row, :format_failure_rate, 1.0),
         :ok <- optional_nonnegative_number(row, :variance, @max_number),
         :ok <- optional_nonnegative_number(row, :marginal_cost, @max_number),
         :ok <- optional_nonnegative_number(row, :latency_ms, @max_number),
         :ok <- optional_nonnegative_number(row, :tok_per_s, @max_number),
         :ok <- optional_text(row, :eval_run_ref),
         :ok <- optional_text(row, :quant),
         :ok <- optional_text(row, :hardware),
         :ok <- optional_timestamp(row, :last_verified) do
      :ok
    end
  end

  defp optional_text(row, key) do
    case row[key] do
      nil ->
        :ok

      value when is_binary(value) ->
        if valid_text?(value, @max_text_bytes),
          do: :ok,
          else: {:error, {:invalid_route_input, {:invalid, {:scoreboard, key}}}}

      _ ->
        {:error, {:invalid_route_input, {:invalid, {:scoreboard, key}}}}
    end
  end

  defp optional_timestamp(row, key) do
    case row[key] do
      nil ->
        :ok

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, _datetime, _offset} when byte_size(value) <= 64 -> :ok
          _ -> {:error, {:invalid_route_input, {:invalid, {:scoreboard, key}}}}
        end

      _ ->
        {:error, {:invalid_route_input, {:invalid, {:scoreboard, key}}}}
    end
  end

  defp optional_number(row, key, minimum, maximum) do
    case row[key] do
      nil ->
        :ok

      value when is_integer(value) and value >= minimum and value <= maximum ->
        :ok

      value when is_float(value) and value == value and value >= minimum and value <= maximum ->
        :ok

      _ ->
        {:error, {:invalid_route_input, {:invalid, {:scoreboard, key}}}}
    end
  end

  defp optional_nonnegative_number(row, key, maximum) do
    optional_number(row, key, 0, maximum)
  end

  defp optional_nonnegative_integer(row, key) do
    case row[key] do
      nil -> :ok
      value when is_integer(value) and value >= 0 and value <= 1_000_000_000 -> :ok
      _ -> {:error, {:invalid_route_input, {:invalid, {:scoreboard, key}}}}
    end
  end

  defp validate_observations(values) when is_list(values) do
    if bounded_list?(values, @max_observations) and
         Enum.all?(values, fn value ->
           match?(%ProviderObservation{}, value) and ProviderObservation.valid?(value)
         end),
       do: {:ok, values},
       else: {:error, {:invalid_route_input, {:invalid, :observations}}}
  end

  defp validate_observations(_values),
    do: {:error, {:invalid_route_input, {:invalid, :observations}}}

  defp validate_budgets(values) when is_list(values) do
    if bounded_list?(values, @max_budgets) and
         Enum.all?(values, fn value ->
           match?(%BudgetSnapshot{}, value) and BudgetSnapshot.valid?(value)
         end),
       do: {:ok, values},
       else: {:error, {:invalid_route_input, {:invalid, :budgets}}}
  end

  defp validate_budgets(_values),
    do: {:error, {:invalid_route_input, {:invalid, :budgets}}}

  defp normalize_policy(policy) when is_map(policy) and not is_struct(policy) do
    if map_size(policy) > @max_map_entries do
      {:error, {:invalid_route_input, {:too_many, :policy}}}
    else
      with {:ok, policy} <- canonical_fields(policy, @policy_keys, :invalid_policy),
           :ok <- validate_strict(policy[:strict_evidence]),
           {:ok, fallback_limit} <- normalize_fallback_limit(policy[:fallback_limit]),
           :ok <- validate_json_clean(policy[:params] || %{}) do
        {:ok,
         Map.merge(
           %{strict_evidence: false, fallback_limit: @max_fallbacks, params: %{}},
           Map.put(policy, :fallback_limit, fallback_limit)
         )}
      end
    end
  end

  defp normalize_policy(_policy), do: {:error, {:invalid_route_input, {:invalid, :policy}}}

  defp validate_strict(nil), do: :ok
  defp validate_strict(value) when is_boolean(value), do: :ok
  defp validate_strict(_value), do: {:error, {:invalid_route_input, {:invalid, :strict_evidence}}}

  defp normalize_fallback_limit(nil), do: {:ok, @max_fallbacks}

  defp normalize_fallback_limit(value)
       when is_integer(value) and value >= 0 and value <= @max_fallbacks,
       do: {:ok, value}

  defp normalize_fallback_limit(_value),
    do: {:error, {:invalid_route_input, {:invalid, :fallback_limit}}}

  defp validate_json_clean(value) do
    case json_clean?(value, 0, @max_json_nodes) do
      {:ok, _remaining} -> :ok
      :error -> {:error, {:invalid_route_input, {:invalid, :params}}}
    end
  end

  defp json_clean?(_value, depth, _nodes) when depth > @max_json_depth, do: :error
  defp json_clean?(_value, _depth, nodes) when nodes < 1, do: :error
  defp json_clean?(nil, _depth, nodes), do: {:ok, nodes - 1}

  defp json_clean?(value, _depth, nodes) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @max_text_bytes,
      do: {:ok, nodes - 1},
      else: :error
  end

  defp json_clean?(value, _depth, nodes) when is_boolean(value), do: {:ok, nodes - 1}

  defp json_clean?(value, _depth, nodes) when is_integer(value) do
    if value <= @max_number and value >= -@max_number, do: {:ok, nodes - 1}, else: :error
  end

  defp json_clean?(value, _depth, nodes) when is_float(value) do
    if value == value and value <= @max_number and value >= -@max_number,
      do: {:ok, nodes - 1},
      else: :error
  end

  defp json_clean?(value, depth, nodes) when is_list(value) do
    if bounded_list?(value, @max_map_entries),
      do: json_clean_list(value, depth + 1, nodes - 1),
      else: :error
  end

  defp json_clean?(value, depth, nodes) when is_map(value) and not is_struct(value) do
    if map_size(value) <= @max_map_entries,
      do: json_clean_map(Map.to_list(value), depth + 1, nodes - 1),
      else: :error
  end

  defp json_clean?(_value, _depth, _nodes), do: :error

  defp json_clean_list([], _depth, nodes), do: {:ok, nodes}

  defp json_clean_list([value | rest], depth, nodes) do
    with {:ok, remaining} <- json_clean?(value, depth, nodes),
         do: json_clean_list(rest, depth, remaining)
  end

  defp json_clean_map([], _depth, nodes), do: {:ok, nodes}

  defp json_clean_map([{key, value} | rest], depth, nodes) do
    if is_binary(key) and byte_size(key) <= @max_text_bytes do
      with {:ok, remaining} <- json_clean?(value, depth, nodes),
           do: json_clean_map(rest, depth, remaining)
    else
      :error
    end
  end

  defp build_candidates(catalog) do
    with {:ok, candidates} <- collect_candidates(catalog, []),
         candidates <- Enum.reverse(candidates),
         false <- duplicate_routes?(candidates) do
      {:ok, candidates}
    else
      true -> {:error, {:invalid_route_input, {:duplicate, :candidate_route}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_candidates([], acc), do: {:ok, acc}

  defp collect_candidates([%ModelEntry{} = model | rest], acc) do
    case Enum.reduce_while(model.providers, {:ok, acc}, fn provider, {:ok, acc} ->
           case Enum.reduce_while(provider.runtimes, {:ok, acc}, fn runtime, {:ok, acc} ->
                  if length(acc) >= @max_candidates do
                    {:halt, {:error, {:invalid_route_input, {:too_many, :candidates}}}}
                  else
                    candidate = %{
                      model: model.canonical_id,
                      provider: Atom.to_string(provider.id),
                      runtime: Atom.to_string(runtime),
                      ref: provider.ref,
                      auth: provider.auth,
                      entry: model
                    }

                    {:cont, {:ok, [candidate | acc]}}
                  end
                end) do
             {:ok, new_acc} -> {:cont, {:ok, new_acc}}
             {:error, reason} -> {:halt, {:error, reason}}
           end
         end) do
      {:ok, acc} -> collect_candidates(rest, acc)
      {:error, reason} -> {:error, reason}
    end
  end

  defp duplicate_routes?(candidates) do
    identities = Enum.map(candidates, &{&1.model, &1.provider, &1.runtime})
    MapSet.size(MapSet.new(identities)) != length(identities)
  end

  defp evaluate_candidates(
         candidates,
         requirements,
         class,
         now,
         policy,
         scoreboard,
         observations,
         budgets
       ) do
    evaluations =
      Enum.map(candidates, fn candidate ->
        evaluate_candidate(
          candidate,
          requirements,
          class,
          now,
          policy,
          scoreboard,
          observations,
          budgets
        )
      end)

    eligible =
      for {:eligible, candidate, metrics, unknown_metrics, row} <- evaluations,
          do: %{
            candidate: candidate,
            metrics: metrics,
            unknown_metrics: unknown_metrics,
            row: row
          }

    if eligible == [] do
      {:error, {:no_eligible_routes, exclusion_summary(evaluations)}}
    else
      ranked = Enum.sort_by(eligible, &ranking_key/1)
      [selected | fallbacks] = ranked
      fallback_limit = policy.fallback_limit

      {:ok,
       %{
         "model" => selected.candidate.model,
         "provider" => selected.candidate.provider,
         "runtime" => selected.candidate.runtime,
         "params" => policy.params,
         "fallback_chain" =>
           Enum.map(Enum.take(fallbacks, fallback_limit), &route_map(&1.candidate)),
         "rationale" => rationale(class, policy, ranked, evaluations)
       }}
    end
  end

  defp evaluate_candidate(
         candidate,
         requirements,
         class,
         now,
         policy,
         scoreboard,
         observations,
         budgets
       ) do
    reasons = requirements_reasons(candidate, requirements)
    exact_model = requirements.requested_model
    matching_observations = matching_observations(candidate, observations)
    active_observations = Enum.reject(matching_observations, &expired?(&1, now))
    observation = latest(active_observations, & &1.observed_at)
    matching_budgets = matching_budgets(candidate, budgets)
    active_budgets = Enum.reject(matching_budgets, &expired?(&1, now))
    budget = latest(active_budgets, & &1.observed_at)
    rows = matching_rows(candidate, class, scoreboard)
    row = List.first(Enum.sort_by(rows, &scoreboard_key(&1, class, candidate)))

    reasons =
      reasons ++
        binding_requirement_reasons(requirements, candidate, observation) ++
        latency_requirement_reasons(requirements, row) ++
        metric_requirement_reasons(requirements, row) ++
        evidence_reasons(
          candidate,
          exact_model,
          matching_observations,
          active_observations,
          observation,
          matching_budgets,
          active_budgets,
          budget,
          row,
          now,
          policy.strict_evidence
        )

    case Enum.uniq(reasons) do
      [] ->
        {metrics, unknown_metrics} = metrics(row, policy.strict_evidence)
        {:eligible, candidate, metrics, unknown_metrics, row}

      reasons ->
        {:excluded, candidate, Enum.sort(reasons)}
    end
  end

  defp requirements_reasons(candidate, requirements) do
    capability_missing =
      (requirements.capabilities || [])
      |> Enum.reject(fn required ->
        atom_to_string_or_binary(required) in Enum.map(
          candidate.entry.capabilities,
          &Atom.to_string/1
        )
      end)

    cond do
      requirements.requested_model &&
          requirements.requested_model not in [candidate.model, candidate.ref] ->
        ["requirements_failed"]

      requirements.runtime && requirements.runtime != candidate.runtime ->
        ["requirements_failed"]

      requirements.runtimes && candidate.runtime not in requirements.runtimes ->
        ["requirements_failed"]

      requirements.provider && requirements.provider != candidate.provider ->
        ["requirements_failed"]

      requirements.providers && candidate.provider not in requirements.providers ->
        ["requirements_failed"]

      requirements.min_context && candidate.entry.context_window < requirements.min_context ->
        ["requirements_failed"]

      capability_missing != [] ->
        ["requirements_failed"]

      true ->
        []
    end
  end

  defp binding_requirement_reasons(%{exact_model_binding: false}, _candidate, _observation),
    do: []

  defp binding_requirement_reasons(
         %{exact_model_binding: true, requested_model: requested},
         candidate,
         observation
       ) do
    if is_nil(requested) or requested not in [candidate.model, candidate.ref] or
         is_nil(observation) or binding_mismatch?(observation, candidate, requested),
       do: ["requirements_failed"],
       else: []
  end

  defp metric_requirement_reasons(requirements, row) do
    checks = [
      {requirements.max_cost, row && row[:marginal_cost], :max_cost},
      {requirements.max_format_failure_rate, row && row[:format_failure_rate],
       :max_format_failure_rate},
      {requirements.max_dangerous_misses, row && row[:dangerous_misses], :max_dangerous_misses}
    ]

    Enum.flat_map(checks, fn
      {nil, _value, _key} -> []
      {_maximum, nil, _key} -> ["requirements_failed"]
      {maximum, value, _key} when value > maximum -> ["requirements_failed"]
      _ -> []
    end)
  end

  defp latency_requirement_reasons(%{max_latency_ms: nil}, _row), do: []

  defp latency_requirement_reasons(%{max_latency_ms: _maximum}, nil),
    do: ["requirements_failed"]

  defp latency_requirement_reasons(%{max_latency_ms: maximum}, row) when is_map(row) do
    if is_nil(row[:latency_ms]) or row[:latency_ms] > maximum,
      do: ["requirements_failed"],
      else: []
  end

  defp latency_requirement_reasons(_requirements, _row), do: []

  defp matching_observations(candidate, observations) do
    Enum.filter(observations, fn observation ->
      observation.provider == candidate.provider and
        (is_nil(observation.runtime) or observation.runtime == candidate.runtime) and
        (is_nil(observation.requested_model_id) or
           observation.requested_model_id in [candidate.model, candidate.ref])
    end)
  end

  defp matching_budgets(candidate, budgets),
    do: Enum.filter(budgets, &(&1.provider == candidate.provider))

  defp matching_rows(candidate, class, rows) do
    Enum.filter(rows, fn row ->
      row.model in [candidate.model, candidate.ref] and
        (is_nil(row.provider) or row.provider == candidate.provider) and
        (is_nil(row.runtime) or row.runtime == candidate.runtime) and
        (is_nil(row.task_class) or row.task_class in [class.resolved, class.requested])
    end)
  end

  defp evidence_reasons(
         candidate,
         exact_model,
         matching,
         active,
         observation,
         matching_budgets,
         active_budgets,
         budget,
         row,
         now,
         strict
       ) do
    expired_reason =
      if Enum.any?(matching, &expired?(&1, now)), do: ["expired_observation"], else: []

    expired_budget_reason =
      if Enum.any?(matching_budgets, &expired?(&1, now)), do: ["expired_budget"], else: []

    explicit_observation_reasons =
      case observation do
        nil ->
          []

        observation ->
          []
          |> add_if(observation.availability == "unavailable", "unavailable")
          |> add_if(
            candidate.auth != :none and observation.auth_health == "expired",
            "auth_expired"
          )
          |> add_if(
            candidate.auth != :none and observation.auth_health == "invalid",
            "auth_invalid"
          )
          |> add_if(
            candidate.auth != :none and observation.auth_health == "unavailable",
            "auth_unavailable"
          )
          |> add_if(observation.model_catalog_membership == "absent", "catalog_absent")
          |> add_if(
            observation.quota_state == "exhausted" or
              (observation.quota_resets_at == nil and observation.quota_state == "exhausted"),
            "quota_exhausted"
          )
          |> add_if(
            observation.subscription_capacity_state == "exhausted",
            "subscription_exhausted"
          )
          |> add_if(
            zero?(observation.concurrency_limit, observation.concurrency_in_use),
            "full_concurrency"
          )
          |> add_if(
            binding_mismatch?(observation, candidate, exact_model),
            "model_binding_mismatch"
          )
      end

    explicit_budget_reasons =
      case budget do
        nil ->
          []

        budget ->
          []
          |> add_if(
            budget.quota_state == "exhausted" or budget.quota_remaining_units == 0,
            "quota_exhausted"
          )
          |> add_if(
            budget.subscription_capacity_state == "exhausted" or
              budget.subscription_capacity_remaining == 0,
            "subscription_exhausted"
          )
          |> add_if(budget.remaining_spend == 0, "zero_remaining_spend")
          |> add_if(
            zero?(budget.concurrency_limit, budget.concurrency_in_use),
            "full_concurrency"
          )
      end

    ambiguity_reasons =
      []
      |> add_if(ambiguous_accounts?(matching), "ambiguous_account_evidence")
      |> add_if(ambiguous_accounts?(matching_budgets), "ambiguous_account_evidence")

    strict_missing =
      if strict do
        missing_evidence_reasons(
          candidate,
          matching,
          active,
          observation,
          matching_budgets,
          active_budgets,
          budget,
          row,
          now
        )
      else
        []
      end

    expired_reason ++
      expired_budget_reason ++
      ambiguity_reasons ++
      explicit_observation_reasons ++ explicit_budget_reasons ++ strict_missing
  end

  defp missing_evidence_reasons(
         candidate,
         matching,
         active,
         observation,
         matching_budgets,
         active_budgets,
         budget,
         row,
         _now
       ) do
    []
    |> add_if(ambiguous_accounts?(matching), "ambiguous_account_evidence")
    |> add_if(ambiguous_accounts?(matching_budgets), "ambiguous_account_evidence")
    |> add_if(matching == [], "missing_evidence:observation")
    |> add_if(matching != [] and active == [], "missing_evidence:observation")
    |> add_if(
      observation != nil and is_nil(observation.availability),
      "missing_evidence:availability"
    )
    |> add_if(
      observation != nil and observation.availability == "unknown",
      "missing_evidence:availability"
    )
    |> add_if(
      candidate.auth != :none and observation != nil and is_nil(observation.auth_health),
      "missing_evidence:auth"
    )
    |> add_if(
      candidate.auth != :none and observation != nil and observation.auth_health == "unknown",
      "missing_evidence:auth"
    )
    |> add_if(
      observation != nil and is_nil(observation.model_catalog_membership),
      "missing_evidence:catalog"
    )
    |> add_if(
      observation != nil and observation.model_catalog_membership == "unknown",
      "missing_evidence:catalog"
    )
    |> add_if(
      matching_budgets == [] or (matching_budgets != [] and active_budgets == []),
      "missing_evidence:budget"
    )
    |> add_if(
      budget != nil and is_nil(budget.remaining_spend) and is_nil(budget.quota_remaining_units) and
        is_nil(budget.subscription_capacity_remaining),
      "missing_evidence:budget_amount"
    )
    |> add_if(
      budget != nil and is_nil(budget.quota_state) and is_nil(budget.quota_remaining_units),
      "missing_evidence:quota"
    )
    |> add_if(
      budget != nil and is_nil(budget.subscription_capacity_state) and
        is_nil(budget.subscription_capacity_remaining),
      "missing_evidence:subscription"
    )
    |> add_if(not concurrency_known?(observation, budget), "missing_evidence:concurrency")
    |> add_if(is_nil(row), "missing_evidence:scoreboard")
    |> add_if(
      row != nil and scoreboard_metrics_missing?(row),
      "missing_evidence:scoreboard_metric"
    )
  end

  defp ambiguous_accounts?(values) do
    values
    |> Enum.map(&(&1.account_id || ""))
    |> MapSet.new()
    |> MapSet.size() > 1
  end

  defp scoreboard_metrics_missing?(row) do
    Enum.any?(
      [:score, :dangerous_misses, :format_failure_rate, :variance, :marginal_cost, :latency_ms],
      &is_nil(row[&1])
    )
  end

  defp concurrency_known?(observation, budget) do
    (observation != nil and not is_nil(observation.concurrency_limit) and
       not is_nil(observation.concurrency_in_use)) or
      (budget != nil and not is_nil(budget.concurrency_limit) and
         not is_nil(budget.concurrency_in_use))
  end

  defp binding_mismatch?(_observation, _candidate, nil), do: false

  defp binding_mismatch?(observation, candidate, requested_model) do
    requested = observation.requested_model_id

    allowed = [requested_model, candidate.model, candidate.ref] |> Enum.reject(&is_nil/1)

    (requested != nil and requested not in allowed) or
      (observation.launch_bound_model_id != nil and
         observation.launch_bound_model_id not in allowed) or
      (observation.confirmed_model_id != nil and observation.confirmed_model_id not in allowed)
  end

  defp zero?(limit, in_use), do: not is_nil(limit) and not is_nil(in_use) and in_use >= limit

  defp expired?(value, now) do
    case value.expires_at do
      nil ->
        false

      expires_at ->
        {:ok, expires, _} = DateTime.from_iso8601(expires_at)
        DateTime.compare(expires, now) != :gt
    end
  end

  defp latest([], _field), do: nil

  defp latest(values, field) do
    Enum.max_by(values, fn value ->
      {:ok, datetime, _} = DateTime.from_iso8601(field.(value))

      {DateTime.to_unix(datetime, :microsecond), value.source, value.account_id || "",
       evidence_bytes(value)}
    end)
  end

  defp scoreboard_key(row, class, candidate) do
    task_specificity =
      cond do
        row.task_class == class.resolved -> 0
        row.task_class == class.requested -> 1
        is_nil(row.task_class) -> 2
        true -> 3
      end

    provider_specificity = if row.provider == candidate.provider, do: 0, else: 1
    runtime_specificity = if row.runtime == candidate.runtime, do: 0, else: 1

    {task_specificity, provider_specificity, runtime_specificity,
     newest_verified(row[:last_verified]), row[:eval_run_ref] || ""}
  end

  defp newest_verified(nil), do: 0

  defp newest_verified(timestamp) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(timestamp)
    -DateTime.to_unix(datetime, :microsecond)
  end

  defp metrics(nil, _strict),
    do:
      {%{
         score: 0,
         dangerous_misses: 1_000_000_000,
         format_failure_rate: 1.0,
         variance: @max_number,
         marginal_cost: @max_number,
         latency_ms: @max_number
       },
       [:score, :dangerous_misses, :format_failure_rate, :variance, :marginal_cost, :latency_ms]}

  defp metrics(row, _strict) do
    defaults = %{
      score: 0,
      dangerous_misses: 1_000_000_000,
      format_failure_rate: 1.0,
      variance: @max_number,
      marginal_cost: @max_number,
      latency_ms: @max_number
    }

    fields = [
      {:score, :score, 0},
      {:dangerous_misses, :dangerous_misses, 1_000_000_000},
      {:format_failure_rate, :format_failure_rate, 1.0},
      {:variance, :variance, @max_number},
      {:marginal_cost, :marginal_cost, @max_number},
      {:latency_ms, :latency_ms, @max_number}
    ]

    Enum.reduce(fields, {defaults, []}, fn {output, key, _default}, {metrics, unknown} ->
      case row[key] do
        nil -> {metrics, [output | unknown]}
        value -> {Map.put(metrics, output, value), unknown}
      end
    end)
    |> then(fn {metrics, unknown} -> {metrics, Enum.sort(unknown)} end)
  end

  defp ranking_key(%{candidate: candidate, metrics: metrics}) do
    {-metrics.score, metrics.dangerous_misses, metrics.format_failure_rate, metrics.variance,
     metrics.marginal_cost, metrics.latency_ms, candidate.model, candidate.provider,
     candidate.runtime}
  end

  defp route_map(candidate),
    do: %{
      "model" => candidate.model,
      "provider" => candidate.provider,
      "runtime" => candidate.runtime
    }

  defp rationale(class, policy, ranked, evaluations) do
    selected = List.first(ranked)

    excluded =
      evaluations
      |> Enum.flat_map(fn
        {:excluded, candidate, reasons} ->
          [
            %{
              "model" => candidate.model,
              "provider" => candidate.provider,
              "runtime" => candidate.runtime,
              "reasons" => reasons
            }
          ]

        _ ->
          []
      end)
      |> Enum.sort_by(&{&1["model"], &1["provider"], &1["runtime"]})

    notes = if class.unknown, do: ["unknown_task_class_defaulted"], else: []

    eligible_ranking =
      ranked
      |> Enum.map(fn entry ->
        %{
          "model" => entry.candidate.model,
          "provider" => entry.candidate.provider,
          "runtime" => entry.candidate.runtime,
          "metrics" => metric_map(entry.metrics),
          "score_provenance" => provenance_map(entry.row)
        }
      end)
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, rank} -> Map.put(entry, "rank", rank) end)

    %{
      "requested_task_class" => class.requested,
      "resolved_task_class" => class.resolved,
      "resolution" => class.resolution,
      "strict_evidence" => policy.strict_evidence,
      "unknown_metrics" => Enum.map(selected.unknown_metrics, &Atom.to_string/1),
      "notes" => notes,
      "excluded" => excluded,
      "eligible_ranking" => eligible_ranking,
      "selected_score_provenance" => provenance_map(selected.row)
    }
  end

  defp metric_map(metrics) do
    %{
      "score" => metrics.score,
      "dangerous_misses" => metrics.dangerous_misses,
      "format_failure_rate" => metrics.format_failure_rate,
      "variance" => metrics.variance,
      "marginal_cost" => metrics.marginal_cost,
      "latency_ms" => metrics.latency_ms
    }
  end

  defp provenance_map(nil), do: %{"eval_run_ref" => nil, "last_verified" => nil}

  defp provenance_map(row),
    do: %{"eval_run_ref" => row[:eval_run_ref], "last_verified" => row[:last_verified]}

  defp exclusion_summary(evaluations) do
    evaluations
    |> Enum.flat_map(fn
      {:excluded, candidate, reasons} ->
        [
          %{
            "model" => candidate.model,
            "provider" => candidate.provider,
            "runtime" => candidate.runtime,
            "reasons" => reasons
          }
        ]

      _ ->
        []
    end)
    |> Enum.sort_by(&{&1["model"], &1["provider"], &1["runtime"]})
    |> Enum.take(@max_candidates)
  end

  defp add_if(list, true, reason), do: [reason | list]
  defp add_if(list, false, _reason), do: list

  defp fetch_alias(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.fetch!(map, Atom.to_string(key))}
      true -> :missing
    end
  end

  defp atom_to_string_or_binary(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string_or_binary(value), do: value

  defp evidence_bytes(%ProviderObservation{} = observation),
    do: ProviderObservation.canonical_bytes(observation) |> elem(1)

  defp evidence_bytes(%BudgetSnapshot{} = snapshot),
    do: BudgetSnapshot.canonical_bytes(snapshot) |> elem(1)
end
