defmodule ArborTui.AliasesClient do
  @moduledoc """
  Signed HTTP client for the `/alias` client command — per-principal agent
  nicknames on the Gateway (`/api/chat/aliases`). Like `AgentsClient` /
  `LifecycleClient`: one short-lived `Mint.HTTP` connection per call, http base
  derived from the WS url, the same `ArborTui.Signer` envelope. The caller runs
  these in a spawned task so the UI never blocks.

    * `list/2`         → `GET /api/chat/aliases`        → `{:ok, %{name => id}}`
    * `set/4`          → `POST /api/chat/aliases`        → `{:ok, map}`
    * `remove/3`       → `DELETE /api/chat/aliases/<n>`  → `{:ok, map}`
  """

  alias ArborTui.AgentsClient
  alias ArborTui.Signer

  @recv_timeout 10_000

  @type result :: {:ok, map()} | {:error, term()}

  @doc "List the principal's saved aliases. Returns `{:ok, %{name => agent_id}}`."
  @spec list(Signer.identity(), String.t()) :: {:ok, map()} | {:error, term()}
  def list(identity, gateway_url) do
    case request(identity, gateway_url, "GET", "/api/chat/aliases", "") do
      {:ok, %{"aliases" => aliases}} when is_map(aliases) -> {:ok, aliases}
      {:ok, _other} -> {:error, :unexpected_body}
      {:error, _} = err -> err
    end
  end

  @doc "Save alias `name` pointing at `target` (id, prefix, or display_name)."
  @spec set(Signer.identity(), String.t(), String.t(), String.t()) :: result()
  def set(identity, gateway_url, name, target) do
    request(identity, gateway_url, "POST", "/api/chat/aliases", %{
      "name" => name,
      "target" => target
    })
  end

  @doc "Remove alias `name`."
  @spec remove(Signer.identity(), String.t(), String.t()) :: result()
  def remove(identity, gateway_url, name) do
    request(identity, gateway_url, "DELETE", "/api/chat/aliases/#{URI.encode(name)}", "")
  end

  # ── signed request ──────────────────────────────────────────────────────────

  defp request(identity, gateway_url, method, path, body_or_map) do
    uri = URI.parse(gateway_url)
    {scheme, host, port} = AgentsClient.http_target(uri)
    body = if is_binary(body_or_map), do: body_or_map, else: Jason.encode!(body_or_map)

    headers =
      [{"authorization", Signer.authorization_header(identity, method, path, body)}] ++
        if(body == "", do: [], else: [{"content-type", "application/json"}])

    with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, method, path, headers, body),
         {:ok, status, resp_body} <- recv_response(conn, ref) do
      handle_response(status, resp_body)
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp handle_response(200, body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  defp handle_response(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => message}} when is_binary(message) ->
        {:error, {:http_error, status, message}}

      _ ->
        {:error, {:http_status, status}}
    end
  end

  # ── HTTP receive loop (same shape as AgentsClient/LifecycleClient) ──────────

  defp recv_response(conn, ref), do: recv_loop(conn, ref, nil, [])

  defp recv_loop(conn, ref, status, body_acc) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            {status, body_acc, done?} = reduce_responses(responses, ref, status, body_acc)

            if done?,
              do: {:ok, status, IO.iodata_to_binary(body_acc)},
              else: recv_loop(conn, ref, status, body_acc)

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
end
