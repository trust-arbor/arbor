defmodule Arbor.Actions.Browser.Query do
  @moduledoc "Query elements matching a CSS selector."

  use Jido.Action,
    name: "browser_query",
    description: "Query elements matching a CSS selector and return their properties",
    category: "browser",
    tags: ["browser", "query", "selector"],
    schema: [
      selector: [type: :string, required: true, doc: "CSS selector to query"],
      limit: [type: :integer, default: 10, doc: "Maximum number of elements to return"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{selector: :control, limit: :data}

  @impl true
  def run(%{selector: selector} = params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: selector})

      case JidoBrowser.Actions.Query.run(Map.put(params, :session, session), %{}) do
        {:ok, result} ->
          Actions.emit_completed(__MODULE__, %{
            selector: selector,
            count: length(result[:elements] || [])
          })

          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, Browser.format_error(reason)}
      end
    end)
  end
end

defmodule Arbor.Actions.Browser.GetText do
  @moduledoc "Get text content of an element."

  use Jido.Action,
    name: "browser_get_text",
    description: "Get the text content of an element",
    category: "browser",
    tags: ["browser", "query", "text"],
    schema: [
      selector: [type: :string, required: true, doc: "CSS selector for the element"],
      all: [type: :boolean, default: false, doc: "Get text from all matching elements"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{selector: :control, all: :data}

  @impl true
  def run(%{selector: selector} = params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: selector})

      case JidoBrowser.Actions.GetText.run(Map.put(params, :session, session), %{}) do
        {:ok, result} ->
          Actions.emit_completed(__MODULE__, %{selector: selector})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, Browser.format_error(reason)}
      end
    end)
  end
end

defmodule Arbor.Actions.Browser.GetAttribute do
  @moduledoc "Get an attribute value from an element."

  use Jido.Action,
    name: "browser_get_attribute",
    description: "Get an attribute value from an element",
    category: "browser",
    tags: ["browser", "query", "attribute"],
    schema: [
      selector: [type: :string, required: true, doc: "CSS selector for the element"],
      attribute: [type: :string, required: true, doc: "Attribute name to retrieve"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{selector: :control, attribute: :control}

  @impl true
  def run(%{selector: selector} = params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: selector, attribute: params.attribute})

      case JidoBrowser.Actions.GetAttribute.run(Map.put(params, :session, session), %{}) do
        {:ok, result} ->
          Actions.emit_completed(__MODULE__, %{selector: selector})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, Browser.format_error(reason)}
      end
    end)
  end
end

defmodule Arbor.Actions.Browser.IsVisible do
  @moduledoc "Check if an element is visible on the page."

  use Jido.Action,
    name: "browser_is_visible",
    description: "Check if an element is visible on the page",
    category: "browser",
    tags: ["browser", "query", "visible"],
    schema: [
      selector: [type: :string, required: true, doc: "CSS selector for the element"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{selector: :control}

  @impl true
  def run(%{selector: selector} = params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: selector})

      case JidoBrowser.Actions.IsVisible.run(Map.put(params, :session, session), %{}) do
        {:ok, result} ->
          Actions.emit_completed(__MODULE__, %{selector: selector, visible: result[:visible]})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, Browser.format_error(reason)}
      end
    end)
  end
end
