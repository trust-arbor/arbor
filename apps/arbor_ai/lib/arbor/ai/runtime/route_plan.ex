defmodule Arbor.AI.Runtime.RoutePlan do
  @moduledoc """
  Pure conversion boundary between `ProviderRouter` decisions and executable
  runtime routes.

  The router deliberately returns JSON-clean provider and runtime strings.
  This module maps those strings back to the exact `%ModelEntry{}` and
  `%ProviderEntry{}` values in the catalog supplied with the route input. It
  never creates atoms and rejects sentinel or module atoms as executable
  selectors.

  `ProviderRouter` currently carries reviewed JSON-clean `policy.params`, but
  the runtime request boundary does not yet expose a matching normalized
  application API. Non-empty params are therefore rejected explicitly in this
  slice instead of being accepted and silently dropped.
  """

  alias Arbor.AI.Runtime.ProviderRouter
  alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}

  @max_route_text_bytes 512
  @max_fallbacks 64

  @enforce_keys [:primary]
  defstruct [:primary, fallbacks: []]

  @type route :: %{
          model_entry: ModelEntry.t(),
          provider: ProviderEntry.t(),
          runtime: atom()
        }

  @type t :: %__MODULE__{
          primary: route(),
          fallbacks: [route()]
        }

  @type error ::
          :invalid_route_input
          | :no_eligible_routes
          | :route_mapping_mismatch
          | :unsupported_route_params
          | :route_decision_failed

  @doc """
  Decide and map an executable primary route plus ordered fallbacks.

  Errors are intentionally reduced to a bounded set so malformed observations
  or router rationale cannot escape through the dispatch boundary.
  """
  @spec build(ProviderRouter.input() | keyword()) :: {:ok, t()} | {:error, error()}
  def build(route_input) do
    with {:ok, decision} <- ProviderRouter.decide_route(route_input),
         {:ok, catalog} <- fetch_catalog(route_input),
         {:ok, plan} <- map_decision(decision, catalog) do
      {:ok, plan}
    else
      {:error, {:invalid_route_input, _reason}} ->
        {:error, :invalid_route_input}

      {:error, {:no_eligible_routes, _summary}} ->
        {:error, :no_eligible_routes}

      {:error, reason}
      when reason in [:invalid_route_input, :route_mapping_mismatch, :unsupported_route_params] ->
        {:error, reason}

      _other ->
        {:error, :route_decision_failed}
    end
  rescue
    _ -> {:error, :route_decision_failed}
  catch
    _, _ -> {:error, :route_decision_failed}
  end

  @doc false
  @spec map_decision(map(), [ModelEntry.t()]) :: {:ok, t()} | {:error, error()}
  def map_decision(decision, catalog)

  def map_decision(%{} = decision, catalog) when is_list(catalog) do
    with :ok <- reject_unsupported_params(decision),
         {:ok, primary} <- map_route(decision, catalog),
         {:ok, fallback_maps} <- fetch_fallbacks(decision),
         {:ok, fallbacks} <- map_routes(fallback_maps, catalog, []) do
      {:ok, %__MODULE__{primary: primary, fallbacks: fallbacks}}
    else
      {:error, :unsupported_route_params} = error -> error
      _ -> {:error, :route_mapping_mismatch}
    end
  end

  def map_decision(_decision, _catalog), do: {:error, :route_mapping_mismatch}

  defp map_routes([], _catalog, acc), do: {:ok, Enum.reverse(acc)}

  defp map_routes([route | rest], catalog, acc) do
    with {:ok, mapped} <- map_route(route, catalog),
         do: map_routes(rest, catalog, [mapped | acc])
  end

  defp map_routes(_routes, _catalog, _acc), do: {:error, :route_mapping_mismatch}

  defp map_route(route, catalog) when is_map(route) do
    with {:ok, model_id} <- fetch_string(route, "model"),
         {:ok, provider_id} <- fetch_string(route, "provider"),
         {:ok, runtime_id} <- fetch_string(route, "runtime"),
         [mapped] <- matching_routes(catalog, model_id, provider_id, runtime_id) do
      {:ok, mapped}
    else
      _ -> {:error, :route_mapping_mismatch}
    end
  end

  defp map_route(_route, _catalog), do: {:error, :route_mapping_mismatch}

  defp matching_routes(catalog, model_id, provider_id, runtime_id) do
    for %ModelEntry{providers: providers} = model <- catalog,
        is_list(providers),
        valid_route_text?(model.canonical_id),
        model.canonical_id == model_id,
        %ProviderEntry{runtimes: runtimes} = provider <- providers,
        is_list(runtimes),
        executable_selector?(provider.id),
        Atom.to_string(provider.id) == provider_id,
        valid_route_text?(provider.ref),
        runtime <- runtimes,
        executable_selector?(runtime),
        Atom.to_string(runtime) == runtime_id do
      %{model_entry: model, provider: provider, runtime: runtime}
    end
  end

  defp executable_selector?(selector) when is_atom(selector) do
    value = Atom.to_string(selector)

    selector not in [nil, true, false] and
      not String.starts_with?(value, "Elixir.") and valid_route_text?(value)
  end

  defp executable_selector?(_selector), do: false

  defp fetch_fallbacks(decision) do
    case Map.fetch(decision, "fallback_chain") do
      {:ok, fallbacks} when is_list(fallbacks) ->
        if bounded_list?(fallbacks, @max_fallbacks),
          do: {:ok, fallbacks},
          else: {:error, :route_mapping_mismatch}

      _ ->
        {:error, :route_mapping_mismatch}
    end
  end

  defp bounded_list?([], _remaining), do: true

  defp bounded_list?([_head | tail], remaining) when remaining > 0,
    do: bounded_list?(tail, remaining - 1)

  defp bounded_list?(_list, _remaining), do: false

  defp reject_unsupported_params(decision) do
    case Map.fetch(decision, "params") do
      {:ok, params} when is_map(params) and not is_struct(params) and map_size(params) == 0 ->
        :ok

      {:ok, params} when is_map(params) and not is_struct(params) ->
        {:error, :unsupported_route_params}

      _ ->
        {:error, :route_mapping_mismatch}
    end
  end

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        if valid_route_text?(value),
          do: {:ok, value},
          else: {:error, :route_mapping_mismatch}

      _ ->
        {:error, :route_mapping_mismatch}
    end
  end

  defp valid_route_text?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) > 0 and
      byte_size(value) <= @max_route_text_bytes and String.trim(value) == value and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp fetch_catalog(input) when is_map(input) and not is_struct(input) do
    case {Map.fetch(input, :catalog), Map.fetch(input, "catalog")} do
      {{:ok, catalog}, :error} when is_list(catalog) -> {:ok, catalog}
      {:error, {:ok, catalog}} when is_list(catalog) -> {:ok, catalog}
      _ -> {:error, :invalid_route_input}
    end
  end

  defp fetch_catalog(input) when is_list(input) do
    atom_catalog = List.keyfind(input, :catalog, 0)
    string_catalog = List.keyfind(input, "catalog", 0)

    case {atom_catalog, string_catalog} do
      {{:catalog, catalog}, nil} when is_list(catalog) -> {:ok, catalog}
      {nil, {"catalog", catalog}} when is_list(catalog) -> {:ok, catalog}
      _ -> {:error, :invalid_route_input}
    end
  end

  defp fetch_catalog(_input), do: {:error, :invalid_route_input}
end
