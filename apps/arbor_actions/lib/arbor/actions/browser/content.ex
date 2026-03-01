defmodule Arbor.Actions.Browser.ExtractContent do
  @moduledoc "Extract page content as markdown or HTML."

  use Jido.Action,
    name: "browser_extract_content",
    description: "Extract page content as markdown or HTML",
    category: "browser",
    tags: ["browser", "content", "extract", "markdown"],
    schema: [
      selector: [type: :string, default: "body", doc: "CSS selector to scope extraction"],
      format: [
        type: {:in, [:markdown, :html]},
        default: :markdown,
        doc: "Output format: markdown or html"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{selector: :control, format: :data}

  @impl true
  def run(params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: params[:selector]})

      case JidoBrowser.Actions.ExtractContent.run(Map.put(params, :session, session), %{}) do
        {:ok, result} ->
          content_length = String.length(result[:content] || "")
          Actions.emit_completed(__MODULE__, %{content_length: content_length})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, Browser.format_error(reason)}
      end
    end)
  end
end

defmodule Arbor.Actions.Browser.Screenshot do
  @moduledoc "Take a screenshot of the current page. Returns base64-encoded image."

  use Jido.Action,
    name: "browser_screenshot",
    description: "Take a screenshot of the current page",
    category: "browser",
    tags: ["browser", "content", "screenshot", "image"],
    schema: [
      full_page: [
        type: :boolean,
        default: false,
        doc: "Capture the full page (not just viewport)"
      ],
      format: [type: {:in, [:png]}, default: :png, doc: "Image format"],
      save_path: [type: :string, doc: "Optional file path to save the screenshot"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{full_page: params[:full_page]})

      case JidoBrowser.Actions.Screenshot.run(Map.put(params, :session, session), %{}) do
        {:ok, result} ->
          Actions.emit_completed(__MODULE__, %{format: params[:format] || :png})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, Browser.format_error(reason)}
      end
    end)
  end
end

defmodule Arbor.Actions.Browser.Snapshot do
  @moduledoc """
  Get an LLM-optimized snapshot of the current page.

  Returns structured data including content, links, forms, and headings.
  Unlike `Arbor.Actions.Web.Snapshot`, this operates on an existing session.
  """

  use Jido.Action,
    name: "browser_snapshot",
    description: "Get an LLM-optimized snapshot of the current page",
    category: "browser",
    tags: ["browser", "content", "snapshot", "ai"],
    schema: [
      selector: [type: :string, default: "body", doc: "CSS selector to scope extraction"],
      include_links: [type: :boolean, default: true, doc: "Include extracted links"],
      include_forms: [type: :boolean, default: true, doc: "Include form field info"],
      include_headings: [type: :boolean, default: true, doc: "Include heading structure"],
      max_content_length: [type: :integer, default: 50_000, doc: "Max content length"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: params[:selector]})

      case JidoBrowser.Actions.Snapshot.run(Map.put(params, :session, session), %{}) do
        {:ok, result} ->
          content_length = String.length(result[:content] || "")
          Actions.emit_completed(__MODULE__, %{content_length: content_length})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, Browser.format_error(reason)}
      end
    end)
  end
end
