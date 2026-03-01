defmodule Arbor.Actions.Browser.Click do
  @moduledoc "Click an element by CSS selector."

  use Jido.Action,
    name: "browser_click",
    description: "Click an element on the page",
    category: "browser",
    tags: ["browser", "interaction", "click"],
    schema: [
      selector: [type: :string, required: true, doc: "CSS selector for the element"],
      text: [type: :string, doc: "Optional text content to match within selector"],
      timeout: [type: :integer, doc: "Timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{selector: :control, text: :data, timeout: :data}

  @impl true
  def run(%{selector: selector} = params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: selector})

      case JidoBrowser.Actions.Click.run(Map.put(params, :session, session), %{}) do
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

defmodule Arbor.Actions.Browser.Type do
  @moduledoc "Type text into an input element."

  use Jido.Action,
    name: "browser_type",
    description: "Type text into an input element",
    category: "browser",
    tags: ["browser", "interaction", "type", "input"],
    schema: [
      selector: [type: :string, required: true, doc: "CSS selector for the input"],
      text: [type: :string, required: true, doc: "Text to type"],
      clear: [type: :boolean, default: false, doc: "Clear existing content first"],
      timeout: [type: :integer, doc: "Timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{selector: :control, text: :data, clear: :data, timeout: :data}

  @impl true
  def run(%{selector: selector} = params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: selector})

      case JidoBrowser.Actions.Type.run(Map.put(params, :session, session), %{}) do
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

defmodule Arbor.Actions.Browser.Hover do
  @moduledoc "Hover over an element (triggers mouse events)."

  use Jido.Action,
    name: "browser_hover",
    description: "Hover over an element to trigger mouse events",
    category: "browser",
    tags: ["browser", "interaction", "hover"],
    schema: [
      selector: [type: :string, required: true, doc: "CSS selector for the element"],
      timeout: [type: :integer, doc: "Timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{selector: :control, timeout: :data}

  @impl true
  def run(%{selector: selector} = params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: selector})

      case JidoBrowser.Actions.Hover.run(Map.put(params, :session, session), %{}) do
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

defmodule Arbor.Actions.Browser.Focus do
  @moduledoc "Focus on an element."

  use Jido.Action,
    name: "browser_focus",
    description: "Set focus on an element",
    category: "browser",
    tags: ["browser", "interaction", "focus"],
    schema: [
      selector: [type: :string, required: true, doc: "CSS selector for the element"],
      timeout: [type: :integer, doc: "Timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{selector: :control, timeout: :data}

  @impl true
  def run(%{selector: selector} = params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: selector})

      case JidoBrowser.Actions.Focus.run(Map.put(params, :session, session), %{}) do
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

defmodule Arbor.Actions.Browser.Scroll do
  @moduledoc "Scroll the page or scroll an element into view."

  use Jido.Action,
    name: "browser_scroll",
    description: "Scroll the page or an element into view",
    category: "browser",
    tags: ["browser", "interaction", "scroll"],
    schema: [
      x: [type: :integer, doc: "Horizontal scroll offset in pixels"],
      y: [type: :integer, doc: "Vertical scroll offset in pixels"],
      direction: [
        type: {:in, [:up, :down, :top, :bottom]},
        doc: "Scroll direction preset"
      ],
      selector: [type: :string, doc: "CSS selector to scroll into view"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{direction: params[:direction]})

      case JidoBrowser.Actions.Scroll.run(Map.put(params, :session, session), %{}) do
        {:ok, result} ->
          Actions.emit_completed(__MODULE__, %{})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, Browser.format_error(reason)}
      end
    end)
  end
end

defmodule Arbor.Actions.Browser.SelectOption do
  @moduledoc "Select an option from a dropdown/select element."

  use Jido.Action,
    name: "browser_select_option",
    description: "Select an option from a dropdown element",
    category: "browser",
    tags: ["browser", "interaction", "select", "form"],
    schema: [
      selector: [type: :string, required: true, doc: "CSS selector for the select element"],
      value: [type: :string, doc: "Option value to select"],
      label: [type: :string, doc: "Option label text to select"],
      index: [type: :integer, doc: "Option index to select (0-based)"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{selector: :control, value: :data, label: :data, index: :data}

  @impl true
  def run(%{selector: selector} = params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: selector})

      case JidoBrowser.Actions.SelectOption.run(Map.put(params, :session, session), %{}) do
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
