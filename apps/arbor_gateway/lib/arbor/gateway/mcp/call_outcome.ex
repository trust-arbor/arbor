defmodule Arbor.Gateway.MCP.CallOutcome do
  @moduledoc """
  Classifies an external MCP tool call into `Arbor.Contracts.Tool.CallFailure`
  outcomes. Pure: no IO, no process state.

  Adapted from Imp's `Imp.MCP.CallFailure` (github.com/deepfates/imp) for the
  shapes ExMCP 1.3 returns from `ExMCP.Client.call_tool/4` with
  `format: :map`:

    * `:not_sent` — the client was not connected or was already gone, the
      target was rejected before a connection opened (URL, network policy,
      DNS, private address, request size, security policy), the connection
      could not be opened (a bare Mint error; ExMCP wraps errors after the
      connection as `:http_request_failed` / `:http_receive_failed`), or
      ExMCP rejected the call's options before sending.
    * `:refused` — the server rejected the request before a method ran:
      JSON-RPC parse error, invalid request or method not found, an HTTP 4xx
      (401 included), or a failed OAuth flow.
    * `:failed` — the tool answered with an MCP error result (`isError`).
    * `:unknown` — everything else once the request may have been delivered:
      a timeout (ExMCP sends synchronous HTTP from inside its client, so a
      call the caller gave up on can still be sent later), invalid params
      (-32602, which a server may send after its tool ran), any other JSON-RPC
      error, a 5xx, a broken stream, an unreadable response, an exit or a
      crash during the call.

  A tool's own answer never reads as `:refused`. An error result is `:failed`
  unless its `structuredContent.outcome` declares `"unknown"`, which only
  makes the classification more cautious.
  """

  alias Arbor.Contracts.Tool.CallFailure

  # JSON-RPC 2.0 section 5.1: each rejects the request before a method runs.
  @refusal_codes [-32_700, -32_600, -32_601]

  # ExMCP.Transport.HTTP.TargetPolicy and the request-size check refuse before
  # a connection is opened.
  @unsent_reasons [
    :invalid_http_url,
    :invalid_network_policy,
    :dns_failed,
    :dns_timeout,
    :non_public_address,
    :non_loopback_address,
    :request_too_large
  ]

  @detail_limit 500

  @doc """
  Classify what `ExMCP.Client.call_tool/4` returned. A successful answer is
  returned unchanged; an error result or an error becomes a `CallFailure`.
  """
  @spec returned(String.t(), String.t(), term()) :: {:ok, term()} | {:error, CallFailure.t()}
  def returned(server_name, tool_name, {:ok, result}) do
    if error_result?(result) do
      outcome = if declared_unknown?(result), do: :unknown, else: :failed
      {:error, failure(outcome, error_result_text(server_name, tool_name, result), tool_name)}
    else
      {:ok, result}
    end
  end

  def returned(server_name, tool_name, {:error, reason}) do
    {:error, failure(classify(reason), error_text(server_name, tool_name, reason), tool_name)}
  end

  def returned(server_name, tool_name, other) do
    {:error,
     failure(
       :unknown,
       "MCP tool #{server_name}/#{tool_name} returned an unrecognized result: #{detail(other)}",
       tool_name
     )}
  end

  @doc """
  Classify an exit caught while calling the client. `:noproc` means the client
  was gone before the call was made; any other exit ended the call while the
  client held it.
  """
  @spec exited(String.t(), String.t(), term()) :: CallFailure.t()
  def exited(server_name, tool_name, {:noproc, _call}) do
    failure(:not_sent, "MCP client for #{server_name} was not running.", tool_name)
  end

  def exited(server_name, tool_name, reason) do
    failure(
      :unknown,
      "MCP client for #{server_name} exited during #{tool_name}: #{detail(reason)}",
      tool_name
    )
  end

  @doc "Classify a raise or throw from inside the client call."
  @spec raised(String.t(), String.t(), atom(), term()) :: CallFailure.t()
  def raised(server_name, tool_name, kind, reason) do
    failure(
      :unknown,
      "MCP call #{server_name}/#{tool_name} crashed (#{kind}): #{detail(reason)}",
      tool_name
    )
  end

  @doc "A call that could not get a connected client."
  @spec not_connected(String.t() | nil, String.t(), term()) :: CallFailure.t()
  def not_connected(server_name, tool_name, status) do
    failure(
      :not_sent,
      "MCP server #{server_name || "connection"} is not connected (#{detail(status)}).",
      tool_name
    )
  end

  @doc """
  A call refused because the tool's pinned fingerprint no longer matches
  the server's advertised definition.
  """
  @spec fingerprint_changed(String.t() | nil, String.t()) :: CallFailure.t()
  def fingerprint_changed(server_name, tool_name) do
    failure(
      :refused,
      "MCP tool #{server_name || "connection"}/#{tool_name} is quarantined after a fingerprint change; re-approve the new pin.",
      tool_name
    )
  end

  @doc false
  @spec classify(term()) :: CallFailure.outcome()
  def classify(:not_connected), do: :not_sent
  def classify(:timeout), do: :unknown
  def classify(%{"code" => code}) when is_integer(code), do: code_outcome(code)
  def classify(%{__struct__: ExMCP.Error.ValidationError}), do: :not_sent

  # An SSE-mode async POST reports its transport's own reason.
  def classify({:transport_error, reason}), do: transport_outcome(reason)

  # ExMCP's request handler reports a failed synchronous send as
  # `%{type: :transport_error, message: "Failed to send request: " <> inspect(reason)}`,
  # so the transport's reason arrives only as that text. These prefixes are
  # the `inspect/1` of the reasons `transport_outcome/1` names.
  def classify(%{type: :transport_error, message: "Failed to send request: " <> text})
      when is_binary(text),
      do: transport_text_outcome(text)

  def classify(_reason), do: :unknown

  defp code_outcome(code) when code in @refusal_codes, do: :refused
  defp code_outcome(_code), do: :unknown

  defp transport_outcome(%{__struct__: Mint.TransportError}), do: :not_sent
  defp transport_outcome(%{__struct__: Mint.HTTPError}), do: :not_sent
  defp transport_outcome(reason) when reason in @unsent_reasons, do: :not_sent
  defp transport_outcome({:security_violation, _error}), do: :not_sent
  defp transport_outcome({:unauthorized, 401, _body, _challenge}), do: :refused
  defp transport_outcome({:oauth_failed, _reason}), do: :refused
  defp transport_outcome({:http_error, status, _body}), do: status_outcome(status)
  defp transport_outcome(_reason), do: :unknown

  defp transport_text_outcome("%Mint.TransportError{" <> _rest), do: :not_sent
  defp transport_text_outcome("%Mint.HTTPError{" <> _rest), do: :not_sent
  defp transport_text_outcome("{:security_violation, " <> _rest), do: :not_sent
  defp transport_text_outcome("{:unauthorized, 401, " <> _rest), do: :refused
  defp transport_text_outcome("{:oauth_failed, " <> _rest), do: :refused

  defp transport_text_outcome("{:http_error, " <> rest) do
    case Integer.parse(rest) do
      {status, _rest} -> status_outcome(status)
      :error -> :unknown
    end
  end

  defp transport_text_outcome(":" <> atom) do
    if Enum.any?(@unsent_reasons, &(Atom.to_string(&1) == atom)), do: :not_sent, else: :unknown
  end

  defp transport_text_outcome(_text), do: :unknown

  # A 4xx says the request was rejected as sent. A 5xx says a server on the
  # path failed, which may be after the MCP server acted.
  defp status_outcome(status) when is_integer(status) and status in 400..499, do: :refused
  defp status_outcome(_status), do: :unknown

  defp error_result?(result) when is_map(result),
    do: Map.get(result, "isError") == true or Map.get(result, :is_error) == true

  defp error_result?(_result), do: false

  defp declared_unknown?(result) do
    case Map.get(result, "structuredContent") || Map.get(result, :structuredOutput) do
      %{"outcome" => "unknown"} -> true
      %{outcome: "unknown"} -> true
      _other -> false
    end
  end

  defp error_result_text(server_name, tool_name, result) do
    texts =
      result
      |> content_items()
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) and text != "" -> [text]
        %{type: "text", text: text} when is_binary(text) and text != "" -> [text]
        _other -> []
      end)

    body =
      case texts do
        [] -> "The tool reported an error without saying what it was."
        texts -> texts |> Enum.join("\n") |> String.slice(0, 4_000)
      end

    "MCP tool #{server_name}/#{tool_name} reported an error: " <> body
  end

  defp content_items(result) do
    case Map.get(result, "content") || Map.get(result, :content) do
      items when is_list(items) -> items
      _other -> []
    end
  end

  defp error_text(server_name, tool_name, :timeout),
    do: "MCP tool #{server_name}/#{tool_name} timed out with no answer."

  defp error_text(server_name, tool_name, %{"code" => code} = error) when is_integer(code) do
    message = if is_binary(error["message"]), do: String.slice(error["message"], 0, 1_000)

    "MCP server #{server_name} returned error #{code} for #{tool_name}: #{message || "no message"}"
  end

  defp error_text(server_name, tool_name, reason),
    do: "MCP call #{server_name}/#{tool_name} failed: #{detail(reason)}"

  defp failure(outcome, message, tool_name) do
    CallFailure.new!(outcome: outcome, message: message, tool: tool_name)
  end

  defp detail(term) do
    term
    |> inspect(limit: 20, printable_limit: @detail_limit)
    |> String.slice(0, @detail_limit)
  end
end
