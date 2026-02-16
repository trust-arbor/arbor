defmodule Arbor.Orchestrator.Handlers.MemoryHandler do
  @moduledoc """
  Handler bridging DOT graph nodes to the Arbor.Memory facade.

  Dispatches by `type` attribute prefix `memory.*`:

    * `memory.recall`        — search/recall memories for context
    * `memory.consolidate`   — run memory consolidation (decay/prune/archive)
    * `memory.index`         — index new content into memory
    * `memory.working_load`  — load working memory into context
    * `memory.working_save`  — save context data back to working memory
    * `memory.stats`         — get memory statistics

  ## Node attributes

    * `source_key`  — context key for content (default varies by subtype)
    * `agent_id`    — override agent_id (default: from context `"session.agent_id"`)
    * `limit`       — max results for recall (default: `"10"`)
    * `strategy`    — consolidation strategy: `"full"`, `"decay_only"`, `"prune_only"`

  Uses `Code.ensure_loaded?/1` + `apply/3` for cross-hierarchy calls.
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  import Arbor.Orchestrator.Handlers.Helpers

  @read_only ~w(memory.recall memory.working_load memory.stats)
  @memory_mod Arbor.Memory

  @impl true
  def execute(node, context, _graph, _opts) do
    type = Map.get(node.attrs, "type", "memory.recall")
    handle_type(type, node, context)
  rescue
    e -> fail("#{Map.get(node.attrs, "type")}: #{Exception.message(e)}")
  end

  @impl true
  def idempotency, do: :side_effecting

  def idempotency_for(type) when type in @read_only, do: :read_only
  def idempotency_for(_type), do: :side_effecting

  # --- Dispatch ---

  defp handle_type("memory.recall", node, context) do
    agent_id = get_agent_id(node, context)
    source_key = Map.get(node.attrs, "source_key", "session.input")
    query = Context.get(context, source_key, "")
    limit = parse_int(Map.get(node.attrs, "limit"), 10)

    case apply(@memory_mod, :recall, [agent_id, query, [limit: limit]]) do
      {:ok, results} when is_list(results) ->
        ok(%{
          "memory.recalled" => results,
          "memory.recall_count" => length(results)
        })

      results when is_list(results) ->
        ok(%{
          "memory.recalled" => results,
          "memory.recall_count" => length(results)
        })

      {:error, reason} ->
        fail("memory.recall failed: #{inspect(reason)}")
    end
  end

  defp handle_type("memory.consolidate", node, context) do
    agent_id = get_agent_id(node, context)
    strategy = Map.get(node.attrs, "strategy")

    opts =
      if strategy do
        [strategy: String.to_existing_atom(strategy)]
      else
        []
      end

    case apply(@memory_mod, :consolidate, [agent_id, opts]) do
      {:ok, result} ->
        ok(%{"memory.consolidation_result" => inspect(result)})

      :ok ->
        ok(%{"memory.consolidation_result" => "completed"})

      {:error, reason} ->
        fail("memory.consolidate failed: #{inspect(reason)}")
    end
  end

  defp handle_type("memory.index", node, context) do
    agent_id = get_agent_id(node, context)
    source_key = Map.get(node.attrs, "source_key", "llm.content")
    content = Context.get(context, source_key)

    unless content do
      throw({:missing, "no content at context key '#{source_key}'"})
    end

    metadata = parse_metadata(node, context)

    case apply(@memory_mod, :index, [agent_id, content, metadata]) do
      {:ok, _} ->
        ok(%{"memory.indexed" => true})

      :ok ->
        ok(%{"memory.indexed" => true})

      {:error, reason} ->
        fail("memory.index failed: #{inspect(reason)}")
    end
  catch
    {:missing, msg} -> fail(msg)
  end

  defp handle_type("memory.working_load", _node, context) do
    agent_id = Context.get(context, "session.agent_id")

    case apply(@memory_mod, :load_working_memory, [agent_id]) do
      {:ok, wm} ->
        ok(%{"memory.working_memory" => wm})

      wm when is_map(wm) ->
        ok(%{"memory.working_memory" => wm})

      {:error, reason} ->
        fail("memory.working_load failed: #{inspect(reason)}")
    end
  end

  defp handle_type("memory.working_save", _node, context) do
    agent_id = Context.get(context, "session.agent_id")
    wm = Context.get(context, "memory.working_memory", %{})

    case apply(@memory_mod, :save_working_memory, [agent_id, wm]) do
      :ok ->
        ok(%{"memory.saved" => true})

      {:ok, _} ->
        ok(%{"memory.saved" => true})

      {:error, reason} ->
        fail("memory.working_save failed: #{inspect(reason)}")
    end
  end

  defp handle_type("memory.stats", _node, context) do
    agent_id = Context.get(context, "session.agent_id")

    index_stats =
      try do
        case apply(@memory_mod, :index_stats, [agent_id]) do
          {:ok, stats} -> stats
          stats when is_map(stats) -> stats
          _ -> %{}
        end
      rescue
        _ -> %{}
      end

    knowledge_stats =
      try do
        case apply(@memory_mod, :knowledge_stats, [agent_id]) do
          {:ok, stats} -> stats
          stats when is_map(stats) -> stats
          _ -> %{}
        end
      rescue
        _ -> %{}
      end

    ok(%{"memory.stats" => inspect(Map.merge(index_stats, knowledge_stats))})
  end

  defp handle_type(type, _node, _context) do
    fail("unknown memory node type: #{type}")
  end

  # --- Helpers ---

  defp get_agent_id(node, context) do
    Map.get(node.attrs, "agent_id") ||
      Context.get(context, "session.agent_id", "orchestrator")
  end

  defp parse_metadata(node, context) do
    case Map.get(node.attrs, "metadata") do
      nil ->
        Context.get(context, "memory.index_metadata", %{})

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} -> map
          _ -> %{}
        end
    end
  end

  defp ok(context_updates) do
    %Outcome{status: :success, context_updates: context_updates}
  end

  defp fail(reason) do
    %Outcome{status: :fail, failure_reason: reason}
  end
end
