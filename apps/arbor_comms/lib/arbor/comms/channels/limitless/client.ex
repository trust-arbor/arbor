defmodule Arbor.Comms.Channels.Limitless.Client do
  @moduledoc """
  HTTP client for the Limitless AI pendant API.

  Fetches transcripts (lifelogs) via the REST API. Used by the
  Limitless channel to poll for new pendant recordings.

  ## Configuration

      config :arbor_comms, :limitless,
        api_key: System.get_env("LIMITLESS_API_KEY"),
        base_url: "https://api.limitless.ai/v1"
  """

  require Logger

  @base_url "https://api.limitless.ai/v1"
  @timeout 30_000

  @type lifelog :: %{
          id: String.t(),
          title: String.t(),
          markdown: String.t() | nil,
          contents: list(map()) | nil,
          start_time: DateTime.t() | nil,
          end_time: DateTime.t() | nil
        }

  @doc """
  Fetch lifelogs from the Limitless API.

  ## Options

  - `:since` - DateTime, fetch lifelogs after this time
  - `:until` - DateTime, fetch lifelogs before this time
  - `:limit` - Integer, max results (default: 50, max: 100)
  - `:include_markdown` - Boolean (default: true)
  - `:include_contents` - Boolean (default: true)
  """
  @spec get_lifelogs(keyword()) :: {:ok, [lifelog()]} | {:error, term()}
  def get_lifelogs(opts \\ []) do
    params = build_params(opts)

    case do_request(:get, "/lifelogs", params) do
      {:ok, %{"data" => %{"lifelogs" => lifelogs}}} when is_list(lifelogs) ->
        parsed = Enum.map(lifelogs, &parse_lifelog/1)
        {:ok, parsed}

      {:ok, %{"data" => nil}} ->
        {:ok, []}

      {:ok, _body} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Test API connectivity and authentication.
  """
  @spec test_connection() :: {:ok, :connected} | {:error, term()}
  def test_connection do
    params = %{limit: 1, includeMarkdown: false, includeContents: false}

    case do_request(:get, "/lifelogs", params) do
      {:ok, _} -> {:ok, :connected}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Extract the best content from a lifelog for messaging.

  Priority: markdown > concatenated contents > title.
  Returns nil if content is too short (< min_length chars).
  """
  @spec extract_content(lifelog(), pos_integer()) :: String.t() | nil
  def extract_content(lifelog, min_length \\ 10) do
    from_markdown(lifelog, min_length) ||
      from_contents(lifelog, min_length) ||
      from_title(lifelog, min_length)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp from_markdown(%{markdown: md}, min_length) when is_binary(md) do
    if String.length(md) >= min_length, do: md, else: nil
  end

  defp from_markdown(_, _), do: nil

  defp from_contents(%{contents: contents}, min_length) when is_list(contents) do
    text =
      contents
      |> Enum.filter(fn item -> item.type in ["transcript", "blockquote"] end)
      |> Enum.map(& &1.content)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    if String.length(text) >= min_length, do: text, else: nil
  end

  defp from_contents(_, _), do: nil

  defp from_title(%{title: title}, min_length) when is_binary(title) do
    if String.length(title) >= min_length, do: title, else: nil
  end

  defp from_title(_, _), do: nil

  defp do_request(method, path, params) do
    url = base_url() <> path

    headers = [
      {"X-API-Key", api_key()},
      {"Accept", "application/json"}
    ]

    req_opts = [
      headers: headers,
      params: params,
      receive_timeout: @timeout
    ]

    Logger.debug("Limitless API request",
      method: method,
      path: path,
      params: inspect(params)
    )

    case apply(Req, method, [url, req_opts]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 401}} ->
        Logger.error("Limitless API authentication failed")
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 429, headers: headers}} ->
        retry_after = get_retry_after(headers)
        Logger.warning("Limitless API rate limited", retry_after: retry_after)
        {:error, {:rate_limited, retry_after}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Limitless API error", status: status, body: inspect(body))
        {:error, {:api_error, status, body}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("Limitless API transport error", reason: inspect(reason))
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        Logger.error("Limitless API request failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp build_params(opts) do
    params = %{
      includeMarkdown: Keyword.get(opts, :include_markdown, true),
      includeContents: Keyword.get(opts, :include_contents, true),
      limit: min(Keyword.get(opts, :limit, 50), 100),
      timezone: "UTC"
    }

    params
    |> maybe_add_time_range(opts)
  end

  defp maybe_add_time_range(params, opts) do
    since = Keyword.get(opts, :since)
    until_time = Keyword.get(opts, :until)

    params
    |> then(fn p ->
      if since, do: Map.put(p, :start, DateTime.to_iso8601(since)), else: p
    end)
    |> then(fn p ->
      if until_time, do: Map.put(p, :end, DateTime.to_iso8601(until_time)), else: p
    end)
  end

  defp parse_lifelog(data) when is_map(data) do
    %{
      id: data["id"],
      title: data["title"],
      markdown: data["markdown"],
      contents: parse_contents(data["contents"]),
      start_time: parse_datetime(data["startTime"]),
      end_time: parse_datetime(data["endTime"])
    }
  end

  defp parse_contents(nil), do: nil

  defp parse_contents(contents) when is_list(contents) do
    Enum.map(contents, fn item ->
      %{
        type: item["type"],
        content: item["content"],
        start_time: parse_datetime(item["startTime"]),
        end_time: parse_datetime(item["endTime"]),
        speaker_name: item["speakerName"],
        speaker_identifier: item["speakerIdentifier"]
      }
    end)
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp get_retry_after(headers) do
    headers
    |> Enum.find_value(60, fn
      {"retry-after", value} -> String.to_integer(value)
      _ -> nil
    end)
  end

  defp api_key do
    config(:api_key) || System.get_env("LIMITLESS_API_KEY") ||
      raise "LIMITLESS_API_KEY not configured"
  end

  defp base_url do
    config(:base_url) || @base_url
  end

  defp config(key) do
    Application.get_env(:arbor_comms, :limitless, [])
    |> Keyword.get(key)
  end
end
