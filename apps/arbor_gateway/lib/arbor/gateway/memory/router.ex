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
  # P0-4: Authorize the *caller* (from conn.assigns.agent_id, set by the
  # gateway's signed-request / JWT auth pipeline) against the *target* agent's
  # memory capability. Pre-fix code passed the target as the principal, which
  # let any authenticated caller read or write any other agent's memory.
  post "/recall" do
    case Schemas.Memory.validate(Schemas.Memory.recall_request(), conn.body_params) do
      {:ok, validated} ->
        agent_id = validated["agent_id"]

        case authorize_memory_access(conn, agent_id, :read) do
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
  # P0-4: Authorize the caller against the target's memory write capability.
  post "/index" do
    case Schemas.Memory.validate(Schemas.Memory.index_request(), conn.body_params) do
      {:ok, validated} ->
        agent_id = validated["agent_id"]

        case authorize_memory_access(conn, agent_id, :write) do
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
  # P0-4: Authorize the caller against the target's memory read capability.
  get "/working/:agent_id" do
    case authorize_memory_access(conn, agent_id, :read) do
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
  # P0-4: Authorize the caller against the target's memory write capability.
  put "/working/:agent_id" do
    case authorize_memory_access(conn, agent_id, :write) do
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
  # P0-4: Authorize the caller against the target's memory read capability —
  # summarize reads the target's context to produce its summary. Previously
  # this route had NO authorization check at all; anyone authenticated could
  # submit text "on behalf of" any agent_id.
  post "/summarize" do
    case Schemas.Memory.validate(Schemas.Memory.summarize_request(), conn.body_params) do
      {:ok, validated} ->
        case authorize_memory_access(conn, validated["agent_id"], :read) do
          :ok ->
            do_summarize(conn, validated)

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

  defp do_summarize(conn, validated) do
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

  # P0-4: Authorize the *caller* (from conn.assigns.agent_id) against the
  # *target's* memory capability. The pre-fix implementation authorized the
  # target as the principal — meaning any authenticated caller could read or
  # mutate any other agent's memory just by supplying their agent_id in the
  # request. The pre-fix code also fell through to :ok on every catch-all,
  # rescue, and "Security not available" path.
  #
  # New contract: only {:ok, :authorized} is permitted. Every other result —
  # missing caller, security unavailable, error, pending approval, rescue,
  # invalid target — denies. The caller_id must come from the gateway's
  # signed-request / JWT auth pipeline (conn.assigns.agent_id), never from
  # the request body.
  defp authorize_memory_access(conn, target_agent_id, action) when is_binary(target_agent_id) do
    caller_id = caller_id_from_conn(conn)
    resource = "arbor://memory/#{action}/#{target_agent_id}"

    cond do
      is_nil(caller_id) ->
        {:error, :no_authenticated_caller}

      not security_available?() ->
        {:error, :security_unavailable}

      true ->
        case Arbor.Security.authorize(caller_id, resource, action) do
          {:ok, :authorized} ->
            :ok

          {:ok, :pending_approval, _} ->
            {:error, :pending_approval}

          {:error, reason} ->
            {:error, reason}

          other ->
            Logger.warning(
              "[MemoryRouter] unexpected authorize/4 result: #{inspect(other)} — denying"
            )

            {:error, {:unexpected_auth_result, other}}
        end
    end
  end

  defp authorize_memory_access(_conn, _target, _action), do: {:error, :invalid_agent_id}

  defp caller_id_from_conn(conn) do
    case conn.assigns[:agent_id] do
      id when is_binary(id) and byte_size(id) > 0 -> id
      _ -> nil
    end
  end

  defp security_available? do
    Code.ensure_loaded?(Arbor.Security) and
      function_exported?(Arbor.Security, :authorize, 4)
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
