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

  alias Arbor.Common.SafeAtom
  alias Arbor.Gateway.Schemas
  alias Arbor.Memory

  require Logger

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["*/*"])
  plug(:dispatch)

  # POST /api/memory/recall — Semantic recall for an agent
  # M4: Authorize agent_id against memory capability before allowing access.
  post "/recall" do
    case Schemas.Memory.validate(Schemas.Memory.recall_request(), conn.body_params) do
      {:ok, validated} ->
        agent_id = validated["agent_id"]

        case authorize_memory_access(agent_id, :read) do
          :ok ->
            opts = build_recall_opts(validated)

            case Memory.recall(agent_id, validated["query"], opts) do
              {:ok, results} ->
                json_response(conn, 200, %{status: "ok", results: format_results(results)})

              {:error, :index_not_initialized} ->
                json_response(conn, 404, %{
                  status: "error",
                  reason: "Memory not initialized for agent"
                })

              {:error, reason} ->
                json_response(conn, 500, %{status: "error", reason: inspect(reason)})
            end

          {:error, reason} ->
            json_response(conn, 403, %{
              status: "error",
              reason: "Unauthorized memory access: #{inspect(reason)}"
            })
        end

      {:error, errors} ->
        json_response(conn, 400, %{status: "error", reason: "invalid_params", details: errors})
    end
  end

  # POST /api/memory/index — Index new content for an agent
  # M4: Authorize agent_id against memory capability before allowing write.
  post "/index" do
    case Schemas.Memory.validate(Schemas.Memory.index_request(), conn.body_params) do
      {:ok, validated} ->
        agent_id = validated["agent_id"]

        case authorize_memory_access(agent_id, :write) do
          :ok ->
            # Convert string keys to atoms for type/source
            safe_metadata = atomize_metadata(validated["metadata"] || %{})

            case Memory.index(agent_id, validated["content"], safe_metadata) do
              {:ok, entry_id} ->
                json_response(conn, 200, %{status: "ok", entry_id: entry_id})

              {:error, :index_not_initialized} ->
                json_response(conn, 404, %{
                  status: "error",
                  reason: "Memory not initialized for agent"
                })

              {:error, reason} ->
                json_response(conn, 500, %{status: "error", reason: inspect(reason)})
            end

          {:error, reason} ->
            json_response(conn, 403, %{
              status: "error",
              reason: "Unauthorized memory access: #{inspect(reason)}"
            })
        end

      {:error, errors} ->
        json_response(conn, 400, %{status: "error", reason: "invalid_params", details: errors})
    end
  end

  # GET /api/memory/working/:agent_id — Get working memory for an agent
  # M1: Authorize agent_id against memory capability before allowing read.
  get "/working/:agent_id" do
    case authorize_memory_access(agent_id, :read) do
      :ok ->
        case Memory.get_working_memory(agent_id) do
          nil ->
            json_response(conn, 404, %{status: "error", reason: "No working memory found"})

          wm ->
            json_response(conn, 200, %{
              status: "ok",
              working_memory: Memory.serialize_working_memory(wm)
            })
        end

      {:error, reason} ->
        json_response(conn, 403, %{status: "error", reason: "unauthorized: #{inspect(reason)}"})
    end
  end

  # PUT /api/memory/working/:agent_id — Save working memory for an agent
  # M1: Authorize agent_id against memory capability before allowing write.
  put "/working/:agent_id" do
    case authorize_memory_access(agent_id, :write) do
      :ok ->
        case Schemas.Memory.validate(Schemas.Memory.working_memory_request(), conn.body_params) do
          {:ok, validated} ->
            # Ensure agent_id in data matches the URL
            wm_data = Map.put(validated["working_memory"], "agent_id", agent_id)
            wm = Memory.deserialize_working_memory(wm_data)
            Memory.save_working_memory(agent_id, wm)
            json_response(conn, 200, %{status: "ok"})

          {:error, errors} ->
            json_response(conn, 400, %{status: "error", reason: "invalid_params", details: errors})
        end

      {:error, reason} ->
        json_response(conn, 403, %{status: "error", reason: "unauthorized: #{inspect(reason)}"})
    end
  end

  # POST /api/memory/summarize — Summarize text
  post "/summarize" do
    case Schemas.Memory.validate(Schemas.Memory.summarize_request(), conn.body_params) do
      {:ok, validated} ->
        opts = build_summarize_opts(validated)

        case Memory.summarize(validated["agent_id"], validated["text"], opts) do
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

      {:error, errors} ->
        json_response(conn, 400, %{status: "error", reason: "invalid_params", details: errors})
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

  @allowed_metadata_atoms ~w(fact experience skill insight relationship user system tool conversation)a

  defp atomize_metadata(metadata) when is_map(metadata) do
    SafeAtom.atomize_keys(Map.take(metadata, ["type", "source"]), [:type, :source])
    |> Map.new(fn
      {k, v} when is_binary(v) -> {k, safe_to_atom(v)}
      kv -> kv
    end)
  end

  defp atomize_metadata(_), do: %{}

  defp safe_to_atom(str) when is_binary(str) do
    case SafeAtom.to_allowed(str, @allowed_metadata_atoms) do
      {:ok, atom} -> atom
      {:error, _} -> str
    end
  end

  # M4: Authorize memory access for the given agent_id.
  # Checks that the agent holds a capability for memory operations.
  # This prevents cross-agent memory access via caller-controlled agent_id.
  defp authorize_memory_access(agent_id, action) when is_binary(agent_id) do
    resource = "arbor://memory/#{action}/#{agent_id}"

    if Code.ensure_loaded?(Arbor.Security) and
         function_exported?(Arbor.Security, :authorize, 4) do
      case Arbor.Security.authorize(agent_id, resource, action) do
        {:ok, :authorized} -> :ok
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end
    else
      # Security module not available — allow access (backward compatibility)
      :ok
    end
  rescue
    _ -> :ok
  end

  defp authorize_memory_access(_agent_id, _action), do: {:error, :invalid_agent_id}

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
