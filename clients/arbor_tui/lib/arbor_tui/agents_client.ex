defmodule ArborTui.AgentsClient do
  @moduledoc """
  Signed HTTP GET for the `/agents` client-local command — lists the agents the
  client is authorized to chat with (`GET /api/chat/agents` on the Gateway).

  This is deliberately a plain HTTP GET, not a WebSocket frame: agent discovery
  has to work while DETACHED (no WS attached), which is exactly when you need it.
  The request is signed with the same `ArborTui.Signer` envelope the WS upgrade
  uses, over `GET /api/chat/agents` with an empty body.

  The HTTP base is derived from the configured gateway WS url
  (`ws://` → `http://`, `wss://` → `https://`, same host/port). One short-lived
  `Mint.HTTP` connection per call (HTTP/1, synchronous receive loop) — the caller
  (`ArborTui.App`) runs this in a spawned task so the UI never blocks.
  """

  alias ArborTui.Signer

  @path "/api/chat/agents"
  @recv_timeout 10_000

  @typedoc "One agent entry as returned by the gateway."
  @type agent :: %{
          agent_id: String.t(),
          display_name: String.t(),
          template: String.t(),
          model: String.t(),
          running: boolean()
        }

  @doc """
  Fetch the authorized-agents list synchronously.

  Returns `{:ok, [agent]}` on a 200 with a well-formed body, or
  `{:error, reason}` on any transport / non-200 / decode failure.
  """
  @spec fetch(Signer.identity(), String.t()) :: {:ok, [agent()]} | {:error, term()}
  def fetch(identity, gateway_url) do
    uri = URI.parse(gateway_url)
    {scheme, host, port} = http_target(uri)
    headers = [{"authorization", Signer.authorization_header(identity, "GET", @path, "")}]

    with {:ok, conn} <- Mint.HTTP.connect(scheme, host, port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.HTTP.request(conn, "GET", @path, headers, ""),
         {:ok, status, body} <- recv_response(conn, ref) do
      handle_response(status, body)
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  @doc """
  Map a gateway WS url to the `{scheme, host, port}` for the HTTP API:
  `ws`/`http` → `:http`, `wss`/`https` → `:https`, same host/port.

  Exported (and pure) so the derivation is testable.
  """
  @spec http_target(URI.t()) :: {:http | :https, String.t(), pos_integer()}
  def http_target(%URI{scheme: scheme, host: host, port: port}) do
    {http_scheme, default_port} =
      case scheme do
        s when s in ["wss", "https"] -> {:https, 443}
        _ -> {:http, 80}
      end

    {http_scheme, host || "localhost", port || default_port}
  end

  # ── HTTP receive loop ──────────────────────────────────────────────────────

  defp recv_response(conn, ref) do
    recv_loop(conn, ref, nil, [])
  end

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

  # ── Response decoding ────────────────────────────────────────────────────

  defp handle_response(200, body) do
    case Jason.decode(body) do
      {:ok, %{"agents" => agents}} when is_list(agents) -> {:ok, Enum.map(agents, &normalize/1)}
      {:ok, _other} -> {:error, :unexpected_body}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp handle_response(status, _body), do: {:error, {:http_status, status}}

  defp normalize(%{"agent_id" => id} = entry) do
    %{
      agent_id: id,
      display_name: Map.get(entry, "display_name", id),
      template: Map.get(entry, "template", "-"),
      model: Map.get(entry, "model", "-"),
      running: Map.get(entry, "running", false) == true
    }
  end

  defp normalize(entry),
    do: %{
      agent_id: inspect(entry),
      display_name: inspect(entry),
      template: "-",
      model: "-",
      running: false
    }
end
