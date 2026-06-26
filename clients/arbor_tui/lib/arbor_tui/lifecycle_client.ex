defmodule ArborTui.LifecycleClient do
  @moduledoc """
  Signed HTTP POSTs for the agent-lifecycle client commands (`/new`, `/start`,
  `/stop`) — they hit the Gateway's lifecycle endpoints:

    * `/new <template> [name]` → `POST /api/chat/agents`
    * `/start <id>`           → `POST /api/chat/agents/<id>/start`
    * `/stop <id>`            → `POST /api/chat/agents/<id>/stop`

  These mirror `ArborTui.AgentsClient` (one short-lived `Mint.HTTP` connection per
  call, http base derived from the WS url) but POST a JSON body. The signature is
  computed over `POST\\n<path>\\n<body>` — so the EXACT body bytes we sign must be
  the bytes we send (we encode once and reuse).

  The caller (`ArborTui.App`) runs these in a spawned task so the UI never blocks.
  Each returns `{:ok, map}` (the gateway's decoded JSON) or `{:error, reason}`.
  """

  alias ArborTui.AgentsClient
  alias ArborTui.Signer

  @recv_timeout 10_000

  @typedoc "Decoded success body from the gateway."
  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  Create+start a new agent from `template` (optional `name`).
  POST `/api/chat/agents`.
  """
  @spec create(Signer.identity(), String.t(), String.t(), String.t() | nil) :: result()
  def create(identity, gateway_url, template, name \\ nil) do
    body =
      %{"template" => template}
      |> maybe_put("name", name)

    post(identity, gateway_url, "/api/chat/agents", body)
  end

  @doc "Start an existing stopped agent. POST `/api/chat/agents/<id>/start`."
  @spec start(Signer.identity(), String.t(), String.t()) :: result()
  def start(identity, gateway_url, agent_id) do
    post(identity, gateway_url, "/api/chat/agents/#{agent_id}/start", %{})
  end

  @doc "Stop a running agent. POST `/api/chat/agents/<id>/stop`."
  @spec stop(Signer.identity(), String.t(), String.t()) :: result()
  def stop(identity, gateway_url, agent_id) do
    post(identity, gateway_url, "/api/chat/agents/#{agent_id}/stop", %{})
  end

  # ── signed POST ────────────────────────────────────────────────────────────

  defp post(identity, gateway_url, path, body_map) do
    uri = URI.parse(gateway_url)
    {scheme, host, port} = AgentsClient.http_target(uri)
    body = Jason.encode!(body_map)

    headers = [
      {"content-type", "application/json"},
      {"authorization", Signer.authorization_header(identity, "POST", path, body)}
    ]

    with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, "POST", path, headers, body),
         {:ok, status, resp_body} <- recv_response(conn, ref) do
      handle_response(status, resp_body)
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── HTTP receive loop (same shape as AgentsClient) ─────────────────────────

  defp recv_response(conn, ref), do: recv_loop(conn, ref, nil, [])

  defp recv_loop(conn, ref, status, body_acc) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            {status, body_acc, done?} = reduce_responses(responses, ref, status, body_acc)

            if done? do
              {:ok, status, IO.iodata_to_binary(body_acc)}
            else
              recv_loop(conn, ref, status, body_acc)
            end

          {:error, _conn, reason, _responses} ->
            {:error, reason}

          :unknown ->
            recv_loop(conn, ref, status, body_acc)
        end
    after
      @recv_timeout -> {:error, :timeout}
    end
  end

  defp reduce_responses(responses, ref, status, body_acc) do
    Enum.reduce(responses, {status, body_acc, false}, fn
      {:status, ^ref, code}, {_status, acc, done?} -> {code, acc, done?}
      {:headers, ^ref, _headers}, acc_state -> acc_state
      {:data, ^ref, data}, {status, acc, done?} -> {status, [acc, data], done?}
      {:done, ^ref}, {status, acc, _done?} -> {status, acc, true}
      _other, acc_state -> acc_state
    end)
  end

  # ── response decoding ──────────────────────────────────────────────────────

  defp handle_response(200, body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :unexpected_body}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  # Non-200: surface the gateway's {"error": "..."} message when present, else
  # the bare status, so the TUI can render a clear reason.
  defp handle_response(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => message}} when is_binary(message) ->
        {:error, {:http_error, status, message}}

      _ ->
        {:error, {:http_status, status}}
    end
  end
end
