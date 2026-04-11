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
          upstream_path: String.t()
        }

  # ===========================================================================
  # Public entry point — called from the mix task
  # ===========================================================================

  @doc """
  Start the proxy with the given config and block until stdin closes.

  Returns `:ok` when the parent process closes its end of the stdio pipe
  (the natural shutdown signal). Returns `{:error, reason}` if the proxy
  fails before entering its main loop (key file not found, parse error,
  etc.).
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts) do
    with {:ok, config} <- build_config(opts) do
      log_stderr("[arbor.signer] starting — agent_id=#{config.key_material.agent_id} upstream=#{config.upstream_url}")
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
         upstream_path: upstream_path
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
        handle_line(line, config)
        loop(config)
    end
  end

  defp handle_line(line, config) do
    trimmed = String.trim_trailing(line, "\n")

    if trimmed == "" do
      :ok
    else
      response = sign_and_forward(trimmed, config)
      write_response(response)
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
  end

  defp sign_and_forward(body, config) do
    case ProxyCore.sign_request(config.key_material, "POST", config.upstream_path, body) do
      {:ok, signed} ->
        forward_signed(body, signed, config)

      {:error, reason} ->
        log_stderr("[arbor.signer] signing failed: #{inspect(reason)}")
        id = parse_id_safely(body)

        ProxyCore.jsonrpc_error_response(id, -32_603, "proxy signing error",
          %{"reason" => inspect(reason)}
        )
        |> Jason.encode!()
    end
  end

  defp forward_signed(body, signed, config) do
    auth_header = ProxyCore.authorization_header_value(signed)

    headers = [
      {"authorization", auth_header},
      {"content-type", "application/json"}
    ]

    case do_post(config.upstream_url, body, headers) do
      {:ok, %{status: 200, body: resp_body}} when is_binary(resp_body) ->
        resp_body

      {:ok, %{status: status, body: resp_body}} ->
        log_stderr("[arbor.signer] upstream returned #{status}: #{inspect(resp_body)}")
        id = parse_id_safely(body)

        ProxyCore.jsonrpc_error_response(
          id,
          -32_603,
          "upstream gateway error (HTTP #{status})",
          %{"upstream_body" => inspect(resp_body)}
        )
        |> Jason.encode!()

      {:error, reason} ->
        log_stderr("[arbor.signer] upstream request failed: #{inspect(reason)}")
        id = parse_id_safely(body)

        ProxyCore.jsonrpc_error_response(id, -32_603, "upstream gateway unreachable",
          %{"reason" => inspect(reason)}
        )
        |> Jason.encode!()
    end
  end

  # Use OTP's built-in :httpc rather than Req. Two reasons:
  #   1. The proxy makes exactly one POST per MCP request — no streaming,
  #      no retries needed at this level (upstream handles its own).
  #   2. Pulling in Req via Application.ensure_all_started transitively
  #      starts the whole umbrella app graph, which collides with the
  #      live dev server when it is already running on port 4000.
  #
  # :httpc is part of :inets, has no in-umbrella dep entanglements, and
  # is more than enough for a one-shot POST. Tests can override the
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
    content_type = headers |> Enum.find_value(~c"application/json", fn
      {"content-type", v} -> String.to_charlist(v)
      _ -> nil
    end)

    httpc_headers =
      headers
      |> Enum.reject(fn {k, _} -> k == "content-type" end)
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    request = {url_chars, httpc_headers, content_type, body}

    case :httpc.request(:post, request, [], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} ->
        {:ok, %{status: status, body: resp_body}}

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
