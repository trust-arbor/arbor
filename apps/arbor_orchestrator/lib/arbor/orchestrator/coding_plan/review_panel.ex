defmodule Arbor.Orchestrator.CodingPlan.ReviewPanel do
  @moduledoc """
  Shell for `ReviewPanelCore`: loads the reviewed code-review council graph,
  extracts its seats (nodes that pin an `llm_provider`), asks the LLM facade
  which providers this host can call, and returns the pure assessment.

  Used by `CodingPlan.Readiness` (the `review_panel` plane) and by
  `mix arbor.coding.check --live`. Never raises: any failure to load or parse
  the graph yields `{:error, reason}` so readiness reports `unobserved`.
  """

  alias Arbor.Orchestrator.CodingPlan.ReviewPanelCore
  alias Arbor.Orchestrator.LlmRouting.ProviderFallbackCore

  @council_pipeline_id "code_review_council"

  @spec observe(map() | nil) :: {:ok, ReviewPanelCore.panel()} | {:error, term()}
  def observe(_plan \\ nil) do
    with {:ok, source} <- council_source(),
         {:ok, graph} <- Arbor.Orchestrator.parse(source) do
      {specific, generic} = fallback_config()
      {:ok, ReviewPanelCore.assess(seats(graph), availability_fun(), specific, generic)}
    end
  rescue
    error -> {:error, {:review_panel_failed, Exception.message(error)}}
  end

  @doc "Seats declared by a parsed council graph: nodes pinning an `llm_provider`."
  @spec seats(term()) :: [ReviewPanelCore.seat()]
  def seats(graph) do
    graph
    |> graph_nodes()
    |> Enum.flat_map(fn {id, node} ->
      attrs = node_attrs(node)
      provider = Map.get(attrs, "llm_provider")

      if is_binary(provider) and provider != "" do
        [%{id: to_string(id), provider: provider, model: Map.get(attrs, "llm_model")}]
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Host fallback table from `config :arbor_orchestrator`, normalized."
  @spec fallback_config() ::
          {ProviderFallbackCore.fallbacks(), [ProviderFallbackCore.candidate()]}
  def fallback_config do
    ProviderFallbackCore.normalize_config(
      Application.get_env(:arbor_orchestrator, :llm_provider_fallbacks, %{}),
      Application.get_env(:arbor_orchestrator, :llm_fallback_providers, [])
    )
  end

  @doc "Availability predicate; overridable for tests via `:llm_provider_availability`."
  @spec availability_fun() :: (String.t() -> boolean())
  def availability_fun do
    case Application.get_env(:arbor_orchestrator, :llm_provider_availability) do
      fun when is_function(fun, 1) -> fun
      # Same rule as the LLM handler: only known-but-down routes fall back.
      _ -> fn p -> Arbor.LLM.provider_route(p) != :unavailable end
    end
  end

  # -- private --------------------------------------------------------------

  defp council_source do
    case Arbor.Actions.reviewed_pipeline(@council_pipeline_id) do
      {:ok, %{source: source}} when is_binary(source) -> {:ok, source}
      {:ok, %{path: path}} when is_binary(path) -> File.read(path)
      {:ok, source} when is_binary(source) -> {:ok, source}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reviewed_pipeline, other}}
    end
  end

  defp graph_nodes(%{nodes: nodes}) when is_map(nodes), do: Map.to_list(nodes)
  defp graph_nodes(%{nodes: nodes}) when is_list(nodes), do: Enum.map(nodes, &{node_id(&1), &1})
  defp graph_nodes(_), do: []

  defp node_id(%{id: id}), do: id
  defp node_id(_), do: nil

  defp node_attrs(%{attrs: attrs}) when is_map(attrs), do: attrs
  defp node_attrs(%{attributes: attrs}) when is_map(attrs), do: attrs
  defp node_attrs(_), do: %{}
end
