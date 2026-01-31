defmodule Arbor.Gateway.Memory.Router do
  @moduledoc """
  Memory API HTTP router for bridged agents.

  Provides endpoints for memory operations via HTTP, enabling
  Claude Code and other external agents to interact with the
  Arbor memory system.

  Mounted at `/api/memory` by the main Gateway router.

  ## Endpoints

  - `POST /recall` — Semantic recall for an agent
  - `POST /index` — Index new content
  - `GET /working/:agent_id` — Get working memory
  - `PUT /working/:agent_id` — Save working memory
  - `POST /summarize` — Summarize text

  ## Request/Response Formats

  ### POST /recall

  Request:
  ```json
  {
    "agent_id": "agent_001",
    "query": "search query",
    "limit": 10,
    "threshold": 0.3,
    "type": "fact"
  }
  ```

  Response:
  ```json
  {
    "status": "ok",
    "results": [
      {"content": "...", "similarity": 0.85, "metadata": {...}}
    ]
  }
  ```

  ### POST /index

  Request:
  ```json
  {
    "agent_id": "agent_001",
    "content": "Content to index",
    "metadata": {"type": "fact", "source": "user"}
  }
  ```

  Response:
  ```json
  {"status": "ok", "entry_id": "mem_abc123"}
  ```

  ### GET /working/:agent_id

  Response:
  ```json
  {
    "status": "ok",
    "working_memory": {
      "agent_id": "agent_001",
      "recent_thoughts": [...],
      "active_goals": [...]
    }
  }
  ```

  ### PUT /working/:agent_id

  Request:
  ```json
  {
    "working_memory": {
      "recent_thoughts": ["thought 1"],
      "active_goals": ["goal 1"]
    }
  }
  ```

  Response:
  ```json
  {"status": "ok"}
  ```

  ### POST /summarize

  Request:
  ```json
  {
    "agent_id": "agent_001",
    "text": "Long text to summarize...",
    "max_length": 500
  }
  ```

  Response:
  ```json
  {
    "status": "ok",
    "summary": "...",
    "complexity": "moderate",
    "model_used": "claude-3-haiku"
  }
  ```
  """

  use Plug.Router

  alias Arbor.Memory
  alias Arbor.Memory.WorkingMemory

  require Logger

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["*/*"])
  plug(:dispatch)

  # POST /api/memory/recall — Semantic recall for an agent
  post "/recall" do
    agent_id = conn.body_params["agent_id"]
    query = conn.body_params["query"]

    if is_nil(agent_id) or is_nil(query) do
      json_response(conn, 400, %{status: "error", reason: "agent_id and query are required"})
    else
      opts = build_recall_opts(conn.body_params)

      case Memory.recall(agent_id, query, opts) do
        {:ok, results} ->
          json_response(conn, 200, %{status: "ok", results: format_results(results)})

        {:error, :index_not_initialized} ->
          json_response(conn, 404, %{status: "error", reason: "Memory not initialized for agent"})

        {:error, reason} ->
          json_response(conn, 500, %{status: "error", reason: inspect(reason)})
      end
    end
  end

  # POST /api/memory/index — Index new content for an agent
  post "/index" do
    agent_id = conn.body_params["agent_id"]
    content = conn.body_params["content"]
    metadata = conn.body_params["metadata"] || %{}

    if is_nil(agent_id) or is_nil(content) do
      json_response(conn, 400, %{status: "error", reason: "agent_id and content are required"})
    else
      # Convert string keys to atoms for type/source
      safe_metadata = atomize_metadata(metadata)

      case Memory.index(agent_id, content, safe_metadata) do
        {:ok, entry_id} ->
          json_response(conn, 200, %{status: "ok", entry_id: entry_id})

        {:error, :index_not_initialized} ->
          json_response(conn, 404, %{status: "error", reason: "Memory not initialized for agent"})

        {:error, reason} ->
          json_response(conn, 500, %{status: "error", reason: inspect(reason)})
      end
    end
  end

  # GET /api/memory/working/:agent_id — Get working memory for an agent
  get "/working/:agent_id" do
    case Memory.get_working_memory(agent_id) do
      nil ->
        json_response(conn, 404, %{status: "error", reason: "No working memory found"})

      wm ->
        json_response(conn, 200, %{status: "ok", working_memory: WorkingMemory.serialize(wm)})
    end
  end

  # PUT /api/memory/working/:agent_id — Save working memory for an agent
  put "/working/:agent_id" do
    wm_data = conn.body_params["working_memory"]

    if is_nil(wm_data) do
      json_response(conn, 400, %{status: "error", reason: "working_memory is required"})
    else
      # Ensure agent_id in data matches the URL
      wm_data = Map.put(wm_data, "agent_id", agent_id)
      wm = WorkingMemory.deserialize(wm_data)
      Memory.save_working_memory(agent_id, wm)
      json_response(conn, 200, %{status: "ok"})
    end
  end

  # POST /api/memory/summarize — Summarize text
  post "/summarize" do
    agent_id = conn.body_params["agent_id"]
    text = conn.body_params["text"]

    if is_nil(agent_id) or is_nil(text) do
      json_response(conn, 400, %{status: "error", reason: "agent_id and text are required"})
    else
      opts = build_summarize_opts(conn.body_params)

      case Memory.summarize(agent_id, text, opts) do
        {:ok, result} ->
          json_response(conn, 200, %{
            status: "ok",
            summary: result.summary,
            complexity: result.complexity,
            model_used: result.model_used
          })

        {:error, {:llm_not_configured, info}} ->
          json_response(conn, 503, %{
            status: "error",
            reason: "LLM not configured",
            complexity: info[:complexity],
            model_needed: info[:model_needed]
          })

        {:error, reason} ->
          json_response(conn, 500, %{status: "error", reason: inspect(reason)})
      end
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  # Private helpers

  defp build_recall_opts(params) do
    opts = []

    opts = if params["limit"], do: [{:limit, params["limit"]} | opts], else: opts
    opts = if params["threshold"], do: [{:threshold, params["threshold"]} | opts], else: opts
    opts = if params["type"], do: [{:type, safe_to_atom(params["type"])} | opts], else: opts

    opts
  end

  defp build_summarize_opts(params) do
    opts = []

    opts = if params["max_length"], do: [{:max_length, params["max_length"]} | opts], else: opts

    opts
  end

  defp format_results(results) do
    Enum.map(results, fn result ->
      %{
        content: result.content,
        similarity: result.similarity,
        metadata: result.metadata
      }
    end)
  end

  defp atomize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take(["type", "source"])
    |> Enum.reduce(%{}, fn
      {"type", v}, acc when is_binary(v) -> Map.put(acc, :type, safe_to_atom(v))
      {"source", v}, acc when is_binary(v) -> Map.put(acc, :source, safe_to_atom(v))
      _, acc -> acc
    end)
  end

  defp atomize_metadata(_), do: %{}

  defp safe_to_atom(str) when is_binary(str) do
    # Only allow known safe atoms for memory types
    allowed = ~w(fact experience skill insight relationship user system tool conversation)

    if str in allowed do
      String.to_existing_atom(str)
    else
      # Return as string if not in allowed list
      str
    end
  rescue
    ArgumentError -> str
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
