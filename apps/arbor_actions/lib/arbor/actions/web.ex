defmodule Arbor.Actions.Web do
  @moduledoc """
  Session-free web browsing and search operations as Jido actions.

  Wraps `jido_browser` self-contained actions with Arbor security integration
  (capability authorization, taint tracking, signal observability, SSRF prevention).
  Each action manages its own browser session lifecycle automatically.

  For interactive browser automation with persistent sessions (navigate, click, type,
  screenshot, etc.), see `Arbor.Actions.Browser`.

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

  # Blocked URL patterns for SSRF prevention
  @blocked_hosts ~w(
    localhost
    127.0.0.1
    0.0.0.0
    [::1]
    169.254.169.254
    metadata.google.internal
  )

  @doc """
  Validate a URL is safe to fetch (no SSRF).

  Blocks:
  - Private/loopback addresses (127.x, 10.x, 172.16-31.x, 192.168.x)
  - Cloud metadata endpoints (169.254.169.254)
  - Non-HTTP schemes (file://, ftp://, data:, javascript:)
  """
  @spec validate_url(String.t()) :: :ok | {:error, String.t()}
  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "Blocked scheme: #{uri.scheme || "none"}. Only http/https allowed."}

      uri.host in @blocked_hosts ->
        {:error, "Blocked host: #{uri.host} (SSRF prevention)"}

      private_ip?(uri.host) ->
        {:error, "Blocked private IP: #{uri.host} (SSRF prevention)"}

      true ->
        :ok
    end
  end

  def validate_url(_), do: {:error, "URL must be a string"}

  defp private_ip?(nil), do: false

  defp private_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, b, _, _}} when b >= 16 and b <= 31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  # ============================================================================
  # Browse Action
  # ============================================================================

  defmodule Browse do
    @moduledoc """
    Read a web page and return its content as markdown, text, or HTML.

    Manages browser session lifecycle automatically. Uses jido_browser's
    ReadPage action under the hood with Arbor security and observability.

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
    alias JidoBrowser.Actions.ReadPage

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

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{url: url} = params, _context) do
      with :ok <- Web.validate_url(url),
           {:ok, format} <- normalize_format(params[:format]) do
        Actions.emit_started(__MODULE__, %{url: url})

        selector = Map.get(params, :selector, "body")

        case ReadPage.run(
               %{url: url, selector: selector, format: format},
               %{}
             ) do
          {:ok, result} ->
            Actions.emit_completed(__MODULE__, %{
              url: url,
              content_length: String.length(result[:content] || "")
            })

            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, format_error(reason)}
        end
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
    def run(%{query: query} = params, _context) do
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
    def run(%{query: query} = params, _context) do
      Actions.emit_started(__MODULE__, %{query: query})

      case System.get_env("EXA_API_KEY") do
        key when is_binary(key) and key != "" ->
          do_search(key, query, params)

        _ ->
          err = "EXA_API_KEY not set"
          Actions.emit_failed(__MODULE__, err)
          {:error, err}
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
    def run(%{query: query} = params, _context) do
      Actions.emit_started(__MODULE__, %{query: query})

      case System.get_env("TINYFISH_API_KEY") do
        key when is_binary(key) and key != "" ->
          do_search(key, query, params)

        _ ->
          err = "TINYFISH_API_KEY not set"
          Actions.emit_failed(__MODULE__, err)
          {:error, err}
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
    alias JidoBrowser.Actions.SnapshotUrl

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

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{url: url} = params, _context) do
      with :ok <- Web.validate_url(url) do
        Actions.emit_started(__MODULE__, %{url: url})

        case SnapshotUrl.run(params, %{}) do
          {:ok, result} ->
            content_length =
              case result do
                %{content: c} when is_binary(c) -> String.length(c)
                _ -> 0
              end

            Actions.emit_completed(__MODULE__, %{
              url: url,
              content_length: content_length,
              has_links: is_list(result[:links]),
              has_forms: is_list(result[:forms])
            })

            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, format_error(reason)}
        end
      end
    end

    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason), do: "Web snapshot failed: #{inspect(reason)}"
  end
end
