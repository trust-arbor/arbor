defmodule Arbor.Common.ProviderFallbackCore do
  @moduledoc """
  Shared by the orchestrator (council seats pinned in reviewed graphs) and
  the advisory council evaluator (`arbor_consensus`, which must not depend on
  `arbor_llm` or `arbor_orchestrator`); lives in `arbor_kernel_runtime` for
  that reason.

  Pure call-time resolution of a node's `llm_provider` / `llm_model` against
  the providers this host can actually call.

  Reviewed graphs such as the code-review council pin a *preferred* provider
  and model per seat. Those graphs are digest-pinned and their launches are
  bound, so the panel must not be adapted by editing or overriding the graph.
  Instead the LLM handler resolves each call: if the preferred provider is
  available, use it; otherwise take the first available candidate from the
  host's reviewed fallback table; if none is available, report it — the seat
  abstains with a reason instead of a generic provider error.

  Inputs are plain data. Availability is a predicate over provider names;
  fallbacks are `%{provider => [{provider, model}]}` for provider-specific
  chains plus an ordered generic list `[{provider, model}]` used when the
  preferred provider has no specific chain.
  """

  @type candidate :: {String.t(), String.t()}
  @type fallbacks :: %{optional(String.t()) => [candidate()]}
  @type resolution ::
          {:ok, {String.t(), String.t()}, :preferred}
          | {:ok, {String.t(), String.t()}, {:fallback, String.t()}}
          | {:error, :no_available_provider, [String.t()]}

  @doc """
  Resolve `provider`/`model`.

  - `available?` — predicate on a provider name.
  - `specific` — per-provider fallback chains.
  - `generic` — ordered generic candidates tried after the specific chain.

  A `nil`/empty provider is returned unchanged as `:preferred` (the handler's
  session default applies; nothing to resolve).
  """
  @spec resolve(
          String.t() | nil,
          String.t() | nil,
          (String.t() -> boolean()),
          fallbacks(),
          [candidate()]
        ) :: resolution()
  def resolve(provider, model, available?, specific, generic)
      when is_function(available?, 1) and is_map(specific) and is_list(generic) do
    cond do
      not is_binary(provider) or provider == "" ->
        {:ok, {provider, model}, :preferred}

      safe_available?(available?, provider) ->
        {:ok, {provider, model}, :preferred}

      true ->
        candidates =
          (Map.get(specific, provider, []) ++ generic)
          |> Enum.filter(&valid_candidate?/1)
          |> Enum.reject(fn {p, _m} -> p == provider end)
          |> Enum.uniq()

        case Enum.find(candidates, fn {p, _m} -> safe_available?(available?, p) end) do
          {p, m} -> {:ok, {p, m}, {:fallback, provider}}
          nil -> {:error, :no_available_provider, Enum.map(candidates, &elem(&1, 0))}
        end
    end
  end

  def resolve(provider, model, _available?, _specific, _generic),
    do: {:ok, {provider, model}, :preferred}

  @doc """
  Normalize host configuration into the `{specific, generic}` fallback inputs.

  Accepts keyword/atom or string keys and `{provider, model}` tuples,
  `[provider, model]` lists, or `%{"provider" => p, "model" => m}` maps so the
  table can live in `config/*.exs` or `.env`-derived runtime config. Malformed
  entries are dropped, never raised.
  """
  @spec normalize_config(term(), term()) :: {fallbacks(), [candidate()]}
  def normalize_config(specific, generic) do
    specific_map =
      case specific do
        map when is_map(map) ->
          map
          |> Enum.map(fn {k, v} -> {to_name(k), normalize_candidates(v)} end)
          |> Enum.filter(fn {k, v} -> is_binary(k) and v != [] end)
          |> Map.new()

        list when is_list(list) ->
          if Keyword.keyword?(list) do
            normalize_config(Map.new(list), generic) |> elem(0)
          else
            %{}
          end

        _ ->
          %{}
      end

    {specific_map, normalize_candidates(generic)}
  end

  @doc false
  @spec normalize_candidates(term()) :: [candidate()]
  def normalize_candidates(list) when is_list(list) do
    list
    |> Enum.map(&normalize_candidate/1)
    |> Enum.filter(&valid_candidate?/1)
    |> Enum.uniq()
  end

  def normalize_candidates(_), do: []

  # -- private --------------------------------------------------------------

  defp normalize_candidate({p, m}), do: {to_name(p), to_name(m)}
  defp normalize_candidate([p, m]), do: {to_name(p), to_name(m)}

  defp normalize_candidate(%{} = map) do
    {to_name(Map.get(map, "provider") || Map.get(map, :provider)),
     to_name(Map.get(map, "model") || Map.get(map, :model))}
  end

  defp normalize_candidate(_), do: nil

  defp valid_candidate?({p, m}) when is_binary(p) and is_binary(m),
    do: p != "" and m != "" and byte_size(p) <= 64 and byte_size(m) <= 128

  defp valid_candidate?(_), do: false

  defp to_name(value) when is_binary(value), do: value
  defp to_name(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp to_name(_), do: nil

  defp safe_available?(available?, provider) do
    available?.(provider) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
