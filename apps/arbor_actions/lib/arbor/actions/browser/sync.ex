defmodule Arbor.Actions.Browser.Wait do
  @moduledoc "Wait for a specified number of milliseconds. No session required."

  use Jido.Action,
    name: "browser_wait",
    description: "Wait for a specified duration",
    category: "browser",
    tags: ["browser", "sync", "wait"],
    schema: [
      ms: [type: :integer, required: true, doc: "Milliseconds to wait"]
    ]

  alias Arbor.Actions

  @impl true
  def run(%{ms: ms} = params, _context) do
    Actions.emit_started(__MODULE__, %{ms: ms})

    case JidoBrowser.Actions.Wait.run(params, %{}) do
      {:ok, result} ->
        Actions.emit_completed(__MODULE__, %{ms: ms})
        {:ok, result}

      {:error, reason} ->
        Actions.emit_failed(__MODULE__, reason)
        {:error, Arbor.Actions.Browser.format_error(reason)}
    end
  end
end

defmodule Arbor.Actions.Browser.WaitForSelector do
  @moduledoc "Wait for an element to reach a specified state (visible, hidden, attached, detached)."

  use Jido.Action,
    name: "browser_wait_for_selector",
    description: "Wait for an element to reach a specified state",
    category: "browser",
    tags: ["browser", "sync", "wait", "selector"],
    schema: [
      selector: [type: :string, required: true, doc: "CSS selector to wait for"],
      state: [
        type: {:in, [:attached, :visible, :hidden, :detached]},
        default: :visible,
        doc: "Target element state"
      ],
      timeout: [type: :integer, default: 30_000, doc: "Timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{selector: :control, state: :data, timeout: :data}

  @impl true
  def run(%{selector: selector} = params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{selector: selector, state: params[:state]})

      case JidoBrowser.Actions.WaitForSelector.run(Map.put(params, :session, session), %{}) do
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

defmodule Arbor.Actions.Browser.WaitForNavigation do
  @moduledoc "Wait for a navigation event to complete."

  use Jido.Action,
    name: "browser_wait_for_navigation",
    description: "Wait for a page navigation to complete",
    category: "browser",
    tags: ["browser", "sync", "wait", "navigation"],
    schema: [
      url: [type: :string, doc: "Optional URL pattern to wait for"],
      timeout: [type: :integer, default: 30_000, doc: "Timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{url: params[:url]})

      case JidoBrowser.Actions.WaitForNavigation.run(Map.put(params, :session, session), %{}) do
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
