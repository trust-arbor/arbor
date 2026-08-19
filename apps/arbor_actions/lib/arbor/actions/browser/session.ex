defmodule Arbor.Actions.Browser.StartSession do
  @moduledoc """
  Start a new browser session. No existing session required.

  Returns `%{session: session, adapter: adapter}` for threading to subsequent actions.

  Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
  the facade-issued envelope fails closed and does not call `jido_browser`.
  The authorized path is `Arbor.Actions.authorize_and_execute/4`, then the
  existing StartSession implementation. This surface never falls back to
  `Arbor.Shell.authorize_and_execute/3`.
  """

  use Jido.Action,
    name: "browser_start_session",
    description: "Start a new browser automation session",
    category: "browser",
    tags: ["browser", "session", "start"],
    schema: [
      headless: [type: :boolean, default: true, doc: "Run browser in headless mode"],
      timeout: [type: :integer, doc: "Session start timeout in ms"],
      adapter: [type: :atom, doc: "Browser adapter to use (default: Vibium)"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_authorized_principal(context, __MODULE__, fn ->
      Actions.emit_started(__MODULE__, params)

      case JidoBrowser.Actions.StartSession.run(params, %{}) do
        {:ok, result} ->
          Actions.emit_completed(__MODULE__, %{adapter: result[:adapter]})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, Browser.format_error(reason)}
      end
    end)
  end
end

defmodule Arbor.Actions.Browser.EndSession do
  @moduledoc """
  End the current browser session and release resources.

  Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
  the facade-issued envelope fails closed and does not call `jido_browser`.
  The authorized path is `Arbor.Actions.authorize_and_execute/4`, then the
  existing EndSession implementation. This surface never falls back to
  `Arbor.Shell.authorize_and_execute/3`.
  """

  use Jido.Action,
    name: "browser_end_session",
    description: "End the current browser session",
    category: "browser",
    tags: ["browser", "session", "end"],
    schema: []

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_authorized_principal(context, __MODULE__, fn ->
      Browser.with_session(context, fn session ->
        Actions.emit_started(__MODULE__, %{})

        case JidoBrowser.Actions.EndSession.run(Map.put(params, :session, session), %{}) do
          {:ok, result} ->
            Actions.emit_completed(__MODULE__, %{})
            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, Browser.format_error(reason)}
        end
      end)
    end)
  end
end

defmodule Arbor.Actions.Browser.GetStatus do
  @moduledoc """
  Get the current browser session status (URL, title, alive?).

  Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
  the facade-issued envelope fails closed and does not call `jido_browser`.
  The authorized path is `Arbor.Actions.authorize_and_execute/4`, then the
  existing GetStatus implementation. This surface never falls back to
  `Arbor.Shell.authorize_and_execute/3`.
  """

  use Jido.Action,
    name: "browser_get_status",
    description: "Get browser session status including current URL and title",
    category: "browser",
    tags: ["browser", "session", "status"],
    schema: []

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_authorized_principal(context, __MODULE__, fn ->
      Browser.with_session(context, fn session ->
        Actions.emit_started(__MODULE__, %{})

        case JidoBrowser.Actions.GetStatus.run(Map.put(params, :session, session), %{}) do
          {:ok, result} ->
            Actions.emit_completed(__MODULE__, %{url: result[:url]})
            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, Browser.format_error(reason)}
        end
      end)
    end)
  end
end
