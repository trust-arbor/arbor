defmodule Arbor.Actions.Web do
  @moduledoc """
  Session-free web browsing and search operations as Jido actions.

  Wraps session-free web operations with Arbor security integration
  (capability authorization, taint tracking, signal observability, SSRF prevention).
  Arbitrary page fetches use Req through a connect-time DNS pin.

  For interactive browser automation with persistent sessions (navigate, click, type,
  screenshot, etc.), see `Arbor.Actions.Browser`.

  Jido actions (`Browse`, `Search`, `Snapshot`, `ExaSearch`, `TinyfishSearch`)
  require `Arbor.Actions.authorized_principal/2`. Direct `run/2` without the
  facade-issued envelope fails closed and never calls `jido_browser` or `Req`
  (or reads provider API keys). The authorized path is
  `Arbor.Actions.authorize_and_execute/4`, then the existing network/credential
  implementation. These actions are not sent through
  `Arbor.Shell.authorize_and_execute/3`. There is no host Web facade.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Browse` | Read a web page and return its content as markdown |
  | `Search` | Search the web via Brave Search API |
  | `Snapshot` | Get an LLM-optimized page snapshot (content, links, forms, headings) |

  ## Authorization

  Capability URIs:
  - `arbor://net/http`
  - `arbor://net/search`
  - `arbor://net/http`

  ## Security

  All URL parameters are validated against SSRF patterns before execution.
  URLs targeting localhost, private networks, and cloud metadata endpoints
  are blocked by default.
  """

  alias Arbor.Common.Sanitizers

  @max_redirects 5
  @test_options_enabled Application.compile_env(
                          :arbor_kernel_runtime,
                          :expose_test_fixtures,
                          false
                        )

  @doc """
  Validate a URL is safe to fetch (no SSRF).

  Blocks:
  - Private/loopback addresses (127.x, 10.x, 172.16-31.x, 192.168.x)
  - Cloud metadata endpoints (169.254.169.254)
  - Non-HTTP schemes (file://, ftp://, data:, javascript:)

  DNS names are accepted only through the Req pinning path used by
  `fetch_page/3`. Interactive browser navigation uses
  `validate_browser_url/1`, which remains fail-closed because that external
  transport cannot preserve a validated IP together with Host/SNI authority.
  """
  @spec validate_url(String.t(), map()) :: :ok | {:error, String.t()}
  def validate_url(url, context \\ %{})

  def validate_url(url, context) when is_binary(url) and is_map(context) do
    case Sanitizers.ssrf_req_options(url, [], ssrf_options(context)) do
      {:ok, _options} -> :ok
      {:error, reason} -> {:error, format_ssrf_error(url, reason)}
    end
  end

  def validate_url(_url, _context), do: {:error, "URL must be a string"}

  @doc false
  @spec validate_browser_url(String.t()) :: :ok | {:error, String.t()}
  def validate_browser_url(url) when is_binary(url) do
    taint = %Arbor.Contracts.Security.Taint{level: :untrusted}

    case Sanitizers.sanitize(:ssrf, url, taint) do
      {:ok, ^url, _taint} ->
        {:error, "Blocked URL (SSRF prevention): browser transport cannot preserve redirect pins"}

      {:error, reason} ->
        {:error, format_ssrf_error(url, reason)}
    end
  end

  def validate_browser_url(_url), do: {:error, "URL must be a string"}

  @doc false
  @spec fetch_page(String.t(), keyword(), map()) ::
          {:ok, %{url: String.t(), status: non_neg_integer(), body: binary()}}
          | {:error, term()}
  def fetch_page(url, request_opts \\ [], context \\ %{})

  def fetch_page(url, request_opts, context)
      when is_binary(url) and is_list(request_opts) and is_map(context) do
    with {:ok, deadline} <- Sanitizers.ssrf_request_deadline(request_opts) do
      do_fetch_page(url, request_opts, context, @max_redirects, deadline)
    end
  end

  def fetch_page(_url, _request_opts, _context), do: {:error, :invalid_web_request}

  @doc false
  def page_content(body, :html) when is_binary(body), do: body
  def page_content(body, format) when is_binary(body) and format in [:markdown, :text], do: body

  @doc false
  def snapshot_result(url, body, params) when is_binary(body) do
    max_length = Map.get(params, :max_content_length, 50_000)

    content =
      if is_integer(max_length) and max_length > 0,
        do: String.slice(body, 0, max_length),
        else: ""

    %{
      url: url,
      title: nil,
      content: content,
      links: if(Map.get(params, :include_links, true), do: [], else: nil),
      forms: if(Map.get(params, :include_forms, true), do: [], else: nil),
      headings: if(Map.get(params, :include_headings, true), do: [], else: nil),
      meta: %{},
      status: "success"
    }
  end

  defp do_fetch_page(_url, _request_opts, _context, redirects_left, _deadline)
       when redirects_left < 0,
       do: {:error, :too_many_redirects}

  defp do_fetch_page(url, request_opts, context, redirects_left, deadline) do
    with {:ok, safe_options} <-
           Sanitizers.ssrf_req_options(url, request_opts, ssrf_options(context), deadline),
         {:ok, %Req.Response{} = response} <- Req.get(url, safe_options) do
      handle_page_response(url, request_opts, context, redirects_left, deadline, response)
    else
      {:error, %Req.TransportError{reason: {:response_bytes_exceeded, maximum}}}
      when is_integer(maximum) and maximum > 0 ->
        {:error, {:response_bytes_exceeded, maximum}}

      {:error, %Req.TransportError{reason: {:invalid_response, reason}}} ->
        {:error, {:invalid_response, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp handle_page_response(url, _request_opts, _context, _redirects_left, _deadline, response)
       when response.status in 200..299 and is_binary(response.body) do
    if String.valid?(response.body) do
      {:ok, %{url: url, status: response.status, body: response.body}}
    else
      {:error, {:invalid_response, :invalid_utf8}}
    end
  end

  defp handle_page_response(url, request_opts, context, redirects_left, deadline, response)
       when response.status in 300..399 do
    case Req.Response.get_header(response, "location") do
      [location | _] when is_binary(location) and location != "" ->
        with {:ok, next_url} <- merge_redirect(url, location),
             :ok <- require_same_origin(url, next_url) do
          do_fetch_page(next_url, request_opts, context, redirects_left - 1, deadline)
        end

      _other ->
        {:error, {:redirect_without_location, response.status}}
    end
  end

  defp handle_page_response(_url, _request_opts, _context, _redirects_left, _deadline, response),
    do: {:error, {:http_status, response.status}}

  defp merge_redirect(url, location) do
    {:ok, url |> URI.merge(location) |> URI.to_string()}
  rescue
    _exception -> {:error, :invalid_redirect_location}
  end

  defp require_same_origin(current_url, next_url) do
    current = URI.parse(current_url)
    next = URI.parse(next_url)

    if origin(current) == origin(next),
      do: :ok,
      else: {:error, {:cross_origin_redirect, next_url}}
  end

  defp origin(uri) do
    scheme = if is_binary(uri.scheme), do: String.downcase(uri.scheme), else: uri.scheme

    host =
      if is_binary(uri.host),
        do: uri.host |> String.downcase() |> String.trim_trailing("."),
        else: uri.host

    port = uri.port || if(scheme == "https", do: 443, else: 80)
    {scheme, host, port}
  end

  defp format_ssrf_error(_url, {:blocked_scheme, scheme}) do
    "Blocked scheme: #{scheme || "none"}. Only http/https allowed. " <>
      "(SSRF prevention: blocked_scheme)"
  end

  defp format_ssrf_error(_url, {:metadata_endpoint, host}) do
    "Blocked host: #{host} (SSRF prevention: metadata_endpoint)"
  end

  defp format_ssrf_error(url, {:private_ip, _address} = reason) do
    case URI.parse(url).host do
      host when host in ["localhost", "metadata.google.internal", "metadata.google.com"] ->
        "Blocked host: #{host} (SSRF prevention: #{inspect(reason)})"

      host ->
        "Blocked private IP: #{host || "unknown"} (SSRF prevention: #{inspect(reason)})"
    end
  end

  defp format_ssrf_error(_url, reason),
    do: "Blocked URL (SSRF prevention): #{inspect(reason)}"

  if @test_options_enabled do
    defp ssrf_options(context) do
      []
      |> maybe_put_option(:resolver, Map.get(context, :ssrf_resolver))
      |> maybe_put_option(:finch_request, Map.get(context, :ssrf_finch_request))
    end

    defp maybe_put_option(options, _key, nil), do: options
    defp maybe_put_option(options, key, value), do: Keyword.put(options, key, value)
  else
    defp ssrf_options(_context), do: []
  end

  # ============================================================================
  # Browse Action
  # ============================================================================

  defmodule Browse do
    @moduledoc """
    Read a web page and return its content as markdown, text, or HTML.

    Fetches through Req with a connect-time DNS pin, then returns the response
    body in the requested representation.

    Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
    the facade-issued envelope fails closed and does not call `jido_browser`
    or `Req`. The authorized path is `Arbor.Actions.authorize_and_execute/4`,
    then the pinned Req fetch. This surface never falls back to
    `Arbor.Shell.authorize_and_execute/3`.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `url` | string | yes | URL to read |
    | `selector` | string | no | CSS selector to scope extraction (default: "body") |
    | `format` | string | no | Output format: "markdown", "text", or "html" (default: "markdown") |

    ## Returns

    - `url` - The URL that was read
    - `content` - The extracted page content
    - `format` - The format used for extraction
    """

    use Jido.Action,
      name: "web_browse",
      description: "Read a web page and return its content as markdown, text, or HTML",
      category: "web",
      tags: ["web", "browse", "read", "content", "markdown"],
      schema: [
        url: [
          type: :string,
          required: true,
          doc: "URL to read"
        ],
        selector: [
          type: :string,
          default: "body",
          doc: "CSS selector to scope extraction"
        ],
        format: [
          type: :string,
          default: "markdown",
          doc: "Output format: markdown, text, or html"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Web
    alias Arbor.Common.SafeAtom
    @allowed_formats [:markdown, :text, :html]

    @doc false
    def taint_roles do
      %{url: {:control, requires: [:ssrf]}, selector: :control, format: :data}
    end

    # Provenance (taint-tracking-rebuild Phase 1): fetched web content crosses
    # the trust boundary — it is untrusted regardless of what it contains.
    @doc false
    def output_taint, do: :untrusted

    # Egress classification (2026-06-14 decision): a fetch is network egress to
    # whatever host the URL names. An arbitrary public host is an uncontrolled
    # peer (:external_peer); loopback/LAN resolve to on-host/on-premises.
    def effect_class, do: :network_egress

    def egress_tier(params, _context) do
      case Arbor.Common.EgressClassifier.locality(params[:url]) do
        :on_host -> :on_host
        :on_premises -> :on_premises
        :public -> :external_peer
      end
    end

    # Destination-scoped egress caps match on the fetched host.
    def egress_destination(params, _context), do: URI.parse(params[:url] || "").host

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{url: url} = params, context) do
      case Actions.authorized_principal(context, __MODULE__) do
        {:ok, _principal_id} ->
          with {:ok, format} <- normalize_format(params[:format]) do
            Actions.emit_started(__MODULE__, %{url: url})

            case Web.fetch_page(url, [receive_timeout: 60_000], context) do
              {:ok, page} ->
                content = Web.page_content(page.body, format)
                result = %{url: page.url, content: content, format: format}

                Actions.emit_completed(__MODULE__, %{
                  url: page.url,
                  content_length: String.length(content)
                })

                {:ok, result}

              {:error, reason} ->
                Actions.emit_failed(__MODULE__, reason)
                {:error, format_error(reason)}
            end
          end

        {:error, reason} ->
          {:error, Actions.unauthorized_message(reason)}
      end
    end

    defp normalize_format(nil), do: {:ok, :markdown}

    defp normalize_format(format) when is_atom(format) and format in @allowed_formats,
      do: {:ok, format}

    defp normalize_format(format) when is_binary(format) do
      case SafeAtom.to_allowed(format, @allowed_formats) do
        {:ok, atom} ->
          {:ok, atom}

        {:error, _} ->
          {:error, "Invalid format '#{format}'. Valid formats: markdown, text, html"}
      end
    end

    defp normalize_format(format),
      do: {:error, "Invalid format '#{inspect(format)}'. Valid formats: markdown, text, html"}

    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason), do: "Web browse failed: #{inspect(reason)}"
  end

  # ============================================================================
  # Search Action
  # ============================================================================

  defmodule Search do
    @moduledoc """
    Search the web using the Brave Search API.

    Returns structured results with titles, URLs, and snippets. Requires a
    Brave Search API key configured via `BRAVE_SEARCH_API_KEY` env var or
    `:jido_browser, :brave_api_key` application config.

    Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
    the facade-issued envelope fails closed and does not call `jido_browser`
    or `Req`. The authorized path is `Arbor.Actions.authorize_and_execute/4`,
    then the existing SearchWeb implementation. This surface never falls back
    to `Arbor.Shell.authorize_and_execute/3`.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `query` | string | yes | Search query |
    | `max_results` | integer | no | Maximum results to return (default: 10, max: 20) |
    | `country` | string | no | Country code for results (default: "us") |
    | `search_lang` | string | no | Language code for results (default: "en") |
    | `freshness` | string | no | Freshness filter: "pd" (24h), "pw" (week), "pm" (month), "py" (year) |

    ## Returns

    - `query` - The search query used
    - `results` - List of result maps with `rank`, `title`, `url`, `snippet`, `age`
    - `count` - Number of results returned
    """

    use Jido.Action,
      name: "web_search",
      description:
        "Search the web using Brave Search API and return structured results " <>
          "with titles, URLs, and snippets",
      category: "web",
      tags: ["web", "search", "brave", "query"],
      schema: [
        query: [
          type: :string,
          required: true,
          doc: "Search query"
        ],
        max_results: [
          type: :integer,
          default: 10,
          doc: "Maximum number of results to return (max 20)"
        ],
        country: [
          type: :string,
          default: "us",
          doc: "Country code for results (e.g., us, gb, de)"
        ],
        search_lang: [
          type: :string,
          default: "en",
          doc: "Language code for results"
        ],
        freshness: [
          type: :string,
          doc: "Freshness filter: pd (24h), pw (week), pm (month), py (year)"
        ]
      ]

    alias Arbor.Actions
    alias JidoBrowser.Actions.SearchWeb

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{query: query} = params, context) do
      case Actions.authorized_principal(context, __MODULE__) do
        {:ok, _principal_id} ->
          Actions.emit_started(__MODULE__, %{query: query})

          case SearchWeb.run(params, %{}) do
            {:ok, result} ->
              Actions.emit_completed(__MODULE__, %{
                query: query,
                result_count: result[:count] || 0
              })

              {:ok, result}

            {:error, reason} ->
              Actions.emit_failed(__MODULE__, reason)
              {:error, format_error(reason)}
          end

        {:error, reason} ->
          {:error, Actions.unauthorized_message(reason)}
      end
    end

    @doc false
    def taint_roles do
      %{query: :control, max_results: :data, country: :data, search_lang: :data, freshness: :data}
    end

    # Egress classification (2026-06-14 decision): a search hits a fixed external
    # search API (a known provider). No destination param to resolve, so the
    # Egress reader's fail-closed default (:external_provider) is correct.
    def effect_class, do: :network_egress

    # Provenance (taint-tracking-rebuild Phase 1): external search results are
    # untrusted content from outside the trust boundary.
    @doc false
    def output_taint, do: :untrusted

    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason), do: "Web search failed: #{inspect(reason)}"
  end

  # ============================================================================
  # Exa Search Action
  # ============================================================================

  defmodule ExaSearch do
    @moduledoc """
    Search the web using the Exa API.

    Exa's distinctive feature for "current trends" research: explicit
    `start_crawl_date` / `max_age_hours` filters target recently-discovered
    pages, and the `mode` opt picks between speed and search-depth modes
    (`instant`/`fast`/`auto`/`deep`/`deep-reasoning`). Returns the same
    shape as `Web.Search` so DOT pipelines can swap providers via the DOT
    node's `action` attr without other plumbing changes.

    Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
    the facade-issued envelope fails closed and does not read `EXA_API_KEY`
    or call `Req`. The authorized path is
    `Arbor.Actions.authorize_and_execute/4`, then the existing Exa request.
    This surface never falls back to `Arbor.Shell.authorize_and_execute/3`.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `query` | string | yes | Search query |
    | `max_results` | integer | no | Maximum results to return (default: 10, max: 100) |
    | `mode` | string | no | One of `instant`/`fast`/`auto`/`deep-lite`/`deep`/`deep-reasoning` (default: `auto`) |
    | `start_crawl_date` | string | no | ISO 8601 date — only return results crawled after this date |
    | `max_age_hours` | integer | no | Force-fetch any cached pages older than this many hours (0 = always fresh) |

    Requires `EXA_API_KEY` in the env.
    """

    use Jido.Action,
      name: "exa_search",
      description:
        "Search the web using Exa's neural search API with crawl-date freshness controls",
      category: "web",
      tags: ["web", "search", "exa", "query"],
      schema: [
        query: [type: :string, required: true, doc: "Search query"],
        max_results: [type: :integer, default: 10, doc: "Maximum results (1–100)"],
        mode: [type: :string, default: "auto", doc: "Exa search mode"],
        start_crawl_date: [type: :string, doc: "ISO 8601 lower bound on crawl date"],
        max_age_hours: [type: :integer, doc: "Cache freshness ceiling in hours"]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{query: query} = params, context) do
      case Actions.authorized_principal(context, __MODULE__) do
        {:ok, _principal_id} ->
          Actions.emit_started(__MODULE__, %{query: query})

          case System.get_env("EXA_API_KEY") do
            key when is_binary(key) and key != "" ->
              do_search(key, query, params)

            _ ->
              err = "EXA_API_KEY not set"
              Actions.emit_failed(__MODULE__, err)
              {:error, err}
          end

        {:error, reason} ->
          {:error, Actions.unauthorized_message(reason)}
      end
    end

    defp do_search(api_key, query, params) do
      body =
        %{
          "query" => query,
          "numResults" => Map.get(params, :max_results, 10),
          "type" => Map.get(params, :mode, "auto"),
          "contents" => %{"highlights" => true, "text" => true}
        }
        |> maybe_put("startCrawlDate", Map.get(params, :start_crawl_date))
        |> maybe_put("maxAgeHours", Map.get(params, :max_age_hours))

      headers = [{"x-api-key", api_key}, {"content-type", "application/json"}]

      case Req.post("https://api.exa.ai/search",
             json: body,
             headers: headers,
             receive_timeout: 60_000
           ) do
        {:ok, %{status: 200, body: %{"results" => results} = response}} when is_list(results) ->
          formatted =
            results
            |> Enum.with_index(1)
            |> Enum.map(fn {r, rank} ->
              %{
                rank: rank,
                title: r["title"] || "",
                url: r["url"] || "",
                snippet: extract_snippet(r),
                age: r["publishedDate"] || ""
              }
            end)

          result = %{
            query: query,
            results: formatted,
            count: length(formatted),
            cost_dollars: response["costDollars"]
          }

          Actions.emit_completed(__MODULE__, %{query: query, result_count: result.count})
          {:ok, result}

        {:ok, %{status: status, body: body}} ->
          err = "Exa search failed: HTTP #{status}: #{inspect(body)}"
          Actions.emit_failed(__MODULE__, err)
          {:error, err}

        {:error, reason} ->
          err = "Exa request failed: #{inspect(reason)}"
          Actions.emit_failed(__MODULE__, err)
          {:error, err}
      end
    end

    defp extract_snippet(%{"highlights" => [first | _]}) when is_binary(first), do: first
    defp extract_snippet(%{"text" => text}) when is_binary(text), do: String.slice(text, 0, 500)
    defp extract_snippet(_), do: ""

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, _key, ""), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    @doc false
    def taint_roles do
      %{
        query: :control,
        max_results: :data,
        mode: :data,
        start_crawl_date: :data,
        max_age_hours: :data
      }
    end

    # Egress classification (2026-06-14 decision): Exa is a fixed external search
    # API — :external_provider via the reader's fail-closed default.
    def effect_class, do: :network_egress

    # Provenance (taint-tracking-rebuild Phase 1): external search results are
    # untrusted content from outside the trust boundary.
    @doc false
    def output_taint, do: :untrusted
  end

  # ============================================================================
  # Tinyfish Search Action
  # ============================================================================

  defmodule TinyfishSearch do
    @moduledoc """
    Search the web using Tinyfish's Search API.

    Tinyfish positions on "fresh, never cached" web search. Their
    OpenAPI spec exposes a deliberately small surface: `query` plus
    optional `location` (country code) and `language`. There's no
    explicit freshness / date / count control — Tinyfish handles
    freshness internally.

    Returns the same `{rank, title, url, snippet, age}` shape as
    `Web.Search` / `Web.ExaSearch` so DOT pipelines can swap
    providers via the `action` attr.

    Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
    the facade-issued envelope fails closed and does not read
    `TINYFISH_API_KEY` or call `Req`. The authorized path is
    `Arbor.Actions.authorize_and_execute/4`, then the existing Tinyfish
    request. This surface never falls back to
    `Arbor.Shell.authorize_and_execute/3`.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `query` | string | yes | Search query |
    | `location` | string | no | Country code, defaults to `us` |
    | `language` | string | no | Language code, defaults to `en` |

    Requires `TINYFISH_API_KEY` in the env. Endpoint per the OpenAPI
    spec is `GET https://api.search.tinyfish.ai/` with the API key
    in the `X-API-Key` header.
    """

    use Jido.Action,
      name: "tinyfish_search",
      description: "Search the web using Tinyfish's fresh-search API",
      category: "web",
      tags: ["web", "search", "tinyfish", "query"],
      schema: [
        query: [type: :string, required: true, doc: "Search query"],
        location: [type: :string, default: "us", doc: "Country code"],
        language: [type: :string, default: "en", doc: "Language code"]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{query: query} = params, context) do
      case Actions.authorized_principal(context, __MODULE__) do
        {:ok, _principal_id} ->
          Actions.emit_started(__MODULE__, %{query: query})

          case System.get_env("TINYFISH_API_KEY") do
            key when is_binary(key) and key != "" ->
              do_search(key, query, params)

            _ ->
              err = "TINYFISH_API_KEY not set"
              Actions.emit_failed(__MODULE__, err)
              {:error, err}
          end

        {:error, reason} ->
          {:error, Actions.unauthorized_message(reason)}
      end
    end

    defp do_search(api_key, query, params) do
      headers = [{"x-api-key", api_key}, {"accept", "application/json"}]

      query_params =
        [
          {"query", query},
          {"location", Map.get(params, :location, "us")},
          {"language", Map.get(params, :language, "en")}
        ]

      case Req.get("https://api.search.tinyfish.ai/",
             params: query_params,
             headers: headers,
             receive_timeout: 60_000
           ) do
        {:ok, %{status: 200, body: %{"results" => results} = response}} when is_list(results) ->
          {:ok, build_result(query, results, response)}

        {:ok, %{status: status, body: body}} ->
          err = "Tinyfish search failed: HTTP #{status}: #{inspect(body)}"
          Actions.emit_failed(__MODULE__, err)
          {:error, err}

        {:error, reason} ->
          err = "Tinyfish request failed: #{inspect(reason)}"
          Actions.emit_failed(__MODULE__, err)
          {:error, err}
      end
    end

    # Tinyfish response shape per its OpenAPI:
    #   results[i]: {position, site_name, title, snippet, url}
    # No publishedDate field — `age` is left empty.
    defp build_result(query, results, response) do
      formatted =
        Enum.map(results, fn r ->
          %{
            rank: r["position"] || 0,
            title: r["title"] || "",
            url: r["url"] || "",
            snippet: r["snippet"] || "",
            age: "",
            site_name: r["site_name"] || ""
          }
        end)

      Actions.emit_completed(__MODULE__, %{query: query, result_count: length(formatted)})

      %{
        query: query,
        results: formatted,
        count: length(formatted),
        total_results: response["total_results"]
      }
    end

    @doc false
    def taint_roles do
      %{query: :control, location: :data, language: :data}
    end

    # Egress classification (2026-06-14 decision): Tinyfish is a fixed external
    # search API — :external_provider via the reader's fail-closed default.
    def effect_class, do: :network_egress

    # Provenance (taint-tracking-rebuild Phase 1): external search results are
    # untrusted content from outside the trust boundary.
    @doc false
    def output_taint, do: :untrusted
  end

  # ============================================================================
  # Snapshot Action
  # ============================================================================

  defmodule Snapshot do
    @moduledoc """
    Get an LLM-optimized snapshot of a web page.

    Returns structured data including page content, extracted links, form fields,
    and heading structure — optimized for AI agent consumption. Falls back to
    markdown extraction if JavaScript evaluation is unavailable.

    Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
    the facade-issued envelope fails closed and does not call `jido_browser`
    or `Req`. The authorized path is `Arbor.Actions.authorize_and_execute/4`,
    then the existing SnapshotUrl implementation. This surface never falls
    back to `Arbor.Shell.authorize_and_execute/3`.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `url` | string | yes | URL to snapshot |
    | `selector` | string | no | CSS selector to scope extraction (default: "body") |
    | `include_links` | boolean | no | Include extracted links (default: true) |
    | `include_forms` | boolean | no | Include form field info (default: true) |
    | `include_headings` | boolean | no | Include heading structure (default: true) |
    | `max_content_length` | integer | no | Truncate content at this length (default: 50000) |

    ## Returns

    - `url` - The page URL
    - `title` - Page title
    - `content` - Page text content
    - `links` - List of extracted links (if enabled)
    - `forms` - List of form structures (if enabled)
    - `headings` - List of headings with levels (if enabled)
    - `meta` - Viewport and scroll metadata
    - `status` - "success"
    """

    use Jido.Action,
      name: "web_snapshot",
      description:
        "Get an LLM-optimized snapshot of a web page including content, links, " <>
          "forms, and heading structure",
      category: "web",
      tags: ["web", "snapshot", "browse", "ai", "structured"],
      schema: [
        url: [
          type: :string,
          required: true,
          doc: "URL to snapshot"
        ],
        selector: [
          type: :string,
          default: "body",
          doc: "CSS selector to scope extraction"
        ],
        include_links: [
          type: :boolean,
          default: true,
          doc: "Include extracted links"
        ],
        include_forms: [
          type: :boolean,
          default: true,
          doc: "Include form field info"
        ],
        include_headings: [
          type: :boolean,
          default: true,
          doc: "Include heading structure"
        ],
        max_content_length: [
          type: :integer,
          default: 50_000,
          doc: "Truncate content at this length"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Web
    @doc false
    def taint_roles do
      %{
        url: {:control, requires: [:ssrf]},
        selector: :control,
        include_links: :data,
        include_forms: :data,
        include_headings: :data,
        max_content_length: :data
      }
    end

    # Provenance (taint-tracking-rebuild Phase 1): a fetched page snapshot is
    # untrusted content from outside the trust boundary.
    @doc false
    def output_taint, do: :untrusted

    # Egress classification (2026-06-14 decision): a snapshot fetches whatever
    # host the URL names — same resolution as Browse.
    def effect_class, do: :network_egress

    def egress_tier(params, _context) do
      case Arbor.Common.EgressClassifier.locality(params[:url]) do
        :on_host -> :on_host
        :on_premises -> :on_premises
        :public -> :external_peer
      end
    end

    # Destination-scoped egress caps match on the fetched host.
    def egress_destination(params, _context), do: URI.parse(params[:url] || "").host

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{url: url} = params, context) do
      case Actions.authorized_principal(context, __MODULE__) do
        {:ok, _principal_id} ->
          Actions.emit_started(__MODULE__, %{url: url})

          case Web.fetch_page(url, [receive_timeout: 60_000], context) do
            {:ok, page} ->
              result = Web.snapshot_result(page.url, page.body, params)
              content_length = String.length(result.content)

              Actions.emit_completed(__MODULE__, %{
                url: page.url,
                content_length: content_length,
                has_links: is_list(result[:links]),
                has_forms: is_list(result[:forms])
              })

              {:ok, result}

            {:error, reason} ->
              Actions.emit_failed(__MODULE__, reason)
              {:error, format_error(reason)}
          end

        {:error, reason} ->
          {:error, Actions.unauthorized_message(reason)}
      end
    end

    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason), do: "Web snapshot failed: #{inspect(reason)}"
  end
end
