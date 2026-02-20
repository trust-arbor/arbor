defmodule Arbor.Actions.Web do
  @moduledoc """
  Web browsing and search operations as Jido actions.

  Wraps `jido_browser` with Arbor security integration (capability authorization,
  taint tracking, signal observability, SSRF prevention).

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Browse` | Read a web page and return its content as markdown |
  | `Search` | Search the web via Brave Search API |
  | `Snapshot` | Get an LLM-optimized page snapshot (content, links, forms, headings) |

  ## Authorization

  Capability URIs:
  - `arbor://actions/execute/web.browse`
  - `arbor://actions/execute/web.search`
  - `arbor://actions/execute/web.snapshot`

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

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{url: url} = params, _context) do
      with :ok <- Web.validate_url(url) do
        Actions.emit_started(__MODULE__, %{url: url})

        format = normalize_format(params[:format])
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

    defp normalize_format(nil), do: :markdown
    defp normalize_format(format) when is_atom(format) and format in @allowed_formats, do: format

    defp normalize_format(format) when is_binary(format) do
      case SafeAtom.to_allowed(format, @allowed_formats) do
        {:ok, atom} -> atom
        {:error, _} -> :markdown
      end
    end

    defp normalize_format(_), do: :markdown

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

    defp format_error(reason) when is_binary(reason), do: reason
    defp format_error(reason), do: "Web search failed: #{inspect(reason)}"
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
