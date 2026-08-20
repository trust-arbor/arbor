defmodule Arbor.Gateway.Signer.Proxy do
  @moduledoc """
  Stdio MCP signing proxy — runs as a subprocess of an MCP client (e.g.,
  Claude Code), reads JSON-RPC requests from stdin, signs each one with the
  agent's Ed25519 private key, forwards them to the upstream Arbor gateway
  over HTTP, and writes the JSON-RPC response back to stdout.

  ## Why a subprocess and not a daemon

  See `.arbor/roadmap/0-inbox/external-agent-registration-mcp.md` and the
  Phase 0 design discussion for the full reasoning. Short version: a stdio
  subprocess inherits its lifetime from its parent (the MCP client) and
  has no listening port that other processes on the box could connect to
  in order to impersonate the agent. The OS process boundary is the
  security boundary.

  ## Wire format the proxy speaks to the gateway

  The upstream is `Arbor.Gateway.SignedRequestAuth`, which expects:

      Authorization: Signature <base64-encoded JSON envelope>

  where the envelope is:

      {"agent_id": "...", "timestamp": "...", "nonce": "...", "signature": "..."}

  and the signature covers the canonical bytes
  `method <> "\\n" <> request_path <> "\\n" <> body`.

  ## Configuration

  Started via `mix arbor.signer --key-file <path> [--upstream <url>]`.

  - `--key-file` (required) — path to the agent's `.arbor.key` file
  - `--upstream` (optional, default `http://localhost:4000/mcp`) — the
    Arbor gateway's MCP endpoint URL

  ## Logging

  Stdout is reserved for MCP protocol traffic (JSON-RPC frames going back
  to the parent process). All log output goes to stderr via `IO.puts/2`
  with `:stderr` device.
  """

  alias Arbor.Gateway.Signer.ProxyCore

  require Logger

  @default_upstream "http://localhost:4000/mcp"

  @typedoc "Runtime configuration for a single proxy session."
  @type config :: %{
          key_material: ProxyCore.key_material(),
          upstream_url: String.t(),
          upstream_path: String.t(),
          session_id: String.t() | nil,
          protocol_version: String.t() | nil,
          cached_initialize_body: String.t() | nil,
          cached_initialized_body: String.t() | nil
        }

  # ===========================================================================
  # Public entry point — called from the mix task
  # ===========================================================================

  @doc """
  Start the proxy with the given config and block until stdin closes.

  Returns `:ok` when the parent process closes its end of the stdio pipe.
  Returns `{:error, reason}` if the proxy fails before entering its main loop
  (key file not found, parse error, etc.).
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts) do
    with {:ok, config} <- build_config(opts) do
      log_stderr(
        "[arbor.signer] starting — agent_id=#{config.key_material.agent_id} upstream=#{config.upstream_url}"
      )

      loop(config)
    else
      {:error, reason} = err ->
        log_stderr("[arbor.signer] startup failed: #{inspect(reason)}")
        err
    end
  end

  # ===========================================================================
  # Configuration
  # ===========================================================================

  defp build_config(opts) do
    with {:ok, key_file_path} <- fetch_required(opts, :key_file),
         {:ok, contents} <- read_key_file(key_file_path),
         {:ok, key_material} <- ProxyCore.parse_key_file(contents) do
      upstream_url = Keyword.get(opts, :upstream, @default_upstream)
      upstream_path = extract_path_from_url(upstream_url)

      {:ok,
       %{
         key_material: key_material,
         upstream_url: upstream_url,
         upstream_path: upstream_path,
         session_id: nil,
         protocol_version: nil,
         cached_initialize_body: nil,
         cached_initialized_body: nil
       }}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required_option, key}}
    end
  end

  defp read_key_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:key_file_read_failed, path, reason}}
    end
  end

  defp extract_path_from_url(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) and path != "" -> path
      _ -> "/"
    end
  end

  # ===========================================================================
  # Main loop — read line, sign, forward, write response
  # ===========================================================================

  defp loop(config) do
    case IO.read(:stdio, :line) do
      :eof ->
        log_stderr("[arbor.signer] stdin closed, exiting")
        :ok

      {:error, reason} ->
        log_stderr("[arbor.signer] stdin read error: #{inspect(reason)}")
        :ok

      line when is_binary(line) ->
        loop(handle_line(line, config))
    end
  end

  defp handle_line(line, config) do
    trimmed = String.trim_trailing(line, "\n")

    if trimmed == "" do
      config
    else
      log_stderr("[arbor.signer] -> #{summarize_request(trimmed)}")

      prepared = ProxyCore.prepare_http_session(config, trimmed)
      {response, config} = sign_and_forward(trimmed, prepared)

      write_response(response)
      config
    end
  rescue
    e ->
      # Defensive: any unexpected error during a single request must NOT kill
      # the loop, or the parent MCP client gets a hung subprocess. Log the
      # error and emit a JSON-RPC error response so the parent sees a clean
      # protocol-level failure.
      log_stderr("[arbor.signer] handle_line crashed: #{Exception.message(e)}")
      err = ProxyCore.jsonrpc_error_response(nil, -32_603, "internal proxy error")
      write_response(Jason.encode!(err))
      config
  end

  defp sign_and_forward(body, config) do
    case sign_and_post(body, config) do
      {:ok, resp} ->
        handle_initial_response(body, config, resp)

      {:error, {:signing_failed, reason}} ->
        log_stderr("[arbor.signer] signing failed: #{inspect(reason)}")
        id = parse_id_safely(body)

        response =
          ProxyCore.jsonrpc_error_response(id, -32_603, "proxy signing error", %{
            "reason" => inspect(reason)
          })
          |> Jason.encode!()

        {response, config}

      {:error, {:upstream_failed, reason}} ->
        upstream_unreachable_response(body, config, reason)
    end
  end

  defp sign_and_post(body, config) do
    case ProxyCore.sign_request(config.key_material, "POST", config.upstream_path, body) do
      {:ok, signed} ->
        headers =
          [
            {"authorization", ProxyCore.authorization_header_value(signed)},
            {"content-type", "application/json"}
          ] ++ ProxyCore.extra_forward_headers(config)

        case do_post(config.upstream_url, body, headers) do
          {:ok, resp} -> {:ok, resp}
          {:error, reason} -> {:error, {:upstream_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:signing_failed, reason}}
    end
  end

  defp handle_initial_response(body, config, resp) do
    case successful_response(body, config, resp) do
      {:ok, result} ->
        result

      :error ->
        status = Map.get(resp, :status)
        response_body = Map.get(resp, :body)

        if ProxyCore.http_session_invalidated?(config, body, status, response_body) do
          recover_and_retry(body, config, status, response_body)
        else
          {upstream_error_response(status, response_body, body), config}
        end
    end
  end

  defp successful_response(body, config, %{status: 200, body: response_body} = resp)
       when is_binary(response_body) do
    {:ok, {response_body, adopt_upstream_session(config, body, resp)}}
  end

  defp successful_response(
         body,
         config,
         %{status: status, body: response_body} = resp
       )
       when status in [202, 204] and response_body in ["", nil] do
    next =
      config
      |> adopt_upstream_session(body, resp)
      |> ProxyCore.remember_successful_initialized(body)

    if jsonrpc_notification?(body) do
      {:ok, {:no_response, next}}
    else
      {:ok, {upstream_error_response(status, response_body, body), next}}
    end
  end

  defp successful_response(_body, _config, _resp), do: :error

  defp recover_and_retry(body, config, status, response_body) do
    with {:ok, recovery_session, plan} <- ProxyCore.begin_http_session_recovery(config),
         {:ok, initialize_resp} <- sign_and_post(plan.initialize_body, recovery_session),
         {:ok, initialized_session} <-
           apply_recovery_response(recovery_session, plan, :initialize, initialize_resp),
         {:ok, initialized_resp} <- sign_and_post(plan.initialized_body, initialized_session),
         {:ok, recovered_session} <-
           apply_recovery_response(initialized_session, plan, :initialized, initialized_resp) do
      log_stderr("[arbor.signer] rehydrated MCP HTTP session after upstream restart")
      retry_original_once(body, recovered_session)
    else
      {:error, reason} ->
        recovery_failure_response(body, config, reason, status, response_body)
    end
  end

  defp apply_recovery_response(session, plan, stage, resp) do
    ProxyCore.apply_http_session_recovery_response(
      session,
      plan,
      stage,
      Map.get(resp, :status),
      Map.get(resp, :headers),
      Map.get(resp, :body)
    )
  end

  defp retry_original_once(body, config) do
    case sign_and_post(body, config) do
      {:ok, resp} ->
        handle_retry_response(body, config, resp)

      {:error, reason} ->
        recovery_failure_response(body, config, {:retry_failed, reason}, nil, nil)
    end
  end

  defp handle_retry_response(body, config, resp) do
    case successful_response(body, config, resp) do
      {:ok, result} ->
        result

      :error ->
        status = Map.get(resp, :status)
        response_body = Map.get(resp, :body)

        if ProxyCore.http_session_invalidated?(config, body, status, response_body) do
          recovery_failure_response(
            body,
            config,
            :retry_session_invalidated,
            status,
            response_body
          )
        else
          {upstream_error_response(status, response_body, body), config}
        end
    end
  end

  defp recovery_failure_response(body, config, reason, status, response_body) do
    log_stderr("[arbor.signer] MCP HTTP session recovery failed: #{inspect(reason)}")

    data =
      %{"reason" => inspect(reason)}
      |> maybe_put_error_data("upstream_status", status)
      |> maybe_put_error_data("upstream_body", response_body)

    response =
      body
      |> parse_id_safely()
      |> ProxyCore.jsonrpc_error_response(
        -32_603,
        "upstream MCP session lost; automatic recovery failed",
        data
      )
      |> Jason.encode!()

    {response, ProxyCore.clear_http_session(config)}
  end

  defp maybe_put_error_data(data, _key, nil), do: data
  defp maybe_put_error_data(data, key, value), do: Map.put(data, key, value)

  defp upstream_unreachable_response(body, config, reason) do
    log_stderr("[arbor.signer] upstream request failed: #{inspect(reason)}")
    id = parse_id_safely(body)

    response =
      ProxyCore.jsonrpc_error_response(id, -32_603, "upstream gateway unreachable", %{
        "reason" => inspect(reason)
      })
      |> Jason.encode!()

    {response, config}
  end

  defp adopt_upstream_session(config, request_body, resp) do
    next =
      ProxyCore.adopt_http_session(
        config,
        Map.get(resp, :headers),
        request_body,
        Map.get(resp, :body)
      )

    if next.session_id not in [nil, config.session_id] do
      log_stderr("[arbor.signer] adopted mcp-session-id from upstream")
    end

    next
  end

  # Use OTP's built-in :httpc rather than Req. Two reasons:
  #   1. Each forwarding step is a simple request/response POST. The only
  #      retry is the explicit, bounded stale-session recovery above.
  #   2. Pulling in Req via Application.ensure_all_started transitively
  #      starts the whole umbrella app graph, which collides with the
  #      live dev server when it is already running on port 4000.
  #
  # :httpc is part of :inets, has no in-umbrella dep entanglements, and
  # is more than enough for these bounded POSTs. Tests can override the
  # client module via Application config if they want to mock.
  defp do_post(url, body, headers) do
    http_client = Application.get_env(:arbor_gateway, :signer_http_client, __MODULE__)

    if http_client == __MODULE__ do
      do_post_httpc(url, body, headers)
    else
      http_client.post(url, body, headers)
    end
  end

  defp do_post_httpc(url, body, headers) do
    # :httpc wants charlist URL and tuple headers
    url_chars = String.to_charlist(url)

    content_type =
      headers
      |> Enum.find_value(~c"application/json", fn
        {"content-type", v} -> String.to_charlist(v)
        _ -> nil
      end)

    httpc_headers =
      headers
      |> Enum.reject(fn {k, _} -> k == "content-type" end)
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    request = {url_chars, httpc_headers, content_type, body}

    case :httpc.request(:post, request, [], body_format: :binary) do
      {:ok, {{_version, status, _reason}, resp_headers, resp_body}} ->
        {:ok, %{status: status, body: resp_body, headers: resp_headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_id_safely(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> ProxyCore.extract_id(parsed)
      _ -> nil
    end
  end

  defp summarize_request(body) do
    case Jason.decode(body) do
      {:ok, %{} = request} ->
        "method=#{inspect(Map.get(request, "method"))} id=#{inspect(Map.get(request, "id"))} bytes=#{byte_size(body)}"

      {:ok, other} ->
        "non-object #{inspect(other)} bytes=#{byte_size(body)}"

      {:error, _} ->
        "unparseable bytes=#{byte_size(body)} prefix=#{inspect(String.slice(body, 0, 80))}"
    end
  end

  defp jsonrpc_notification?(body) do
    case Jason.decode(body) do
      {:ok, %{"jsonrpc" => "2.0", "method" => method} = request} when is_binary(method) ->
        not Map.has_key?(request, "id")

      _ ->
        false
    end
  end

  defp upstream_error_response(status, resp_body, request_body) do
    log_stderr("[arbor.signer] upstream returned #{status}: #{inspect(resp_body)}")
    id = parse_id_safely(request_body)

    ProxyCore.jsonrpc_error_response(
      id,
      -32_603,
      "upstream gateway error (HTTP #{status})",
      %{"upstream_body" => inspect(resp_body)}
    )
    |> Jason.encode!()
  end

  defp write_response(:no_response), do: :ok

  defp write_response(response_bytes) when is_binary(response_bytes) do
    # MCP stdio framing is newline-delimited JSON. Each response is one line.
    # We strip any embedded newlines from the upstream body and append exactly
    # one trailing newline so the parent's line reader stays in sync.
    flattened = String.replace(response_bytes, "\n", "")
    IO.write(:stdio, flattened <> "\n")
  end

  # ===========================================================================
  # Stderr logging — never write log output to stdout, that's the protocol channel
  # ===========================================================================

  defp log_stderr(message) when is_binary(message) do
    IO.puts(:stderr, message)
  end
end
