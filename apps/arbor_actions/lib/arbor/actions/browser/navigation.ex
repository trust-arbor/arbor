defmodule Arbor.Actions.Browser.Navigate do
  @moduledoc """
  Navigate to a URL. SSRF-validated.

  Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
  the facade-issued envelope fails closed and does not call `jido_browser`.
  The authorized path is `Arbor.Actions.authorize_and_execute/4`, then
  `Web.validate_url/1` and the existing Navigate implementation. This
  surface never falls back to `Arbor.Shell.authorize_and_execute/3`.
  """

  use Jido.Action,
    name: "browser_navigate",
    description: "Navigate the browser to a URL",
    category: "browser",
    tags: ["browser", "navigation", "url"],
    schema: [
      url: [type: :string, required: true, doc: "URL to navigate to"],
      timeout: [type: :integer, doc: "Navigation timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.{Browser, Web}

  def taint_roles, do: %{url: {:control, requires: [:ssrf]}, timeout: :data}

  @impl true
  def run(%{url: url} = params, context) do
    Browser.with_authorized_principal(context, __MODULE__, fn ->
      with :ok <- Web.validate_url(url) do
        Browser.with_session(context, fn session ->
          Actions.emit_started(__MODULE__, %{url: url})

          case JidoBrowser.Actions.Navigate.run(Map.put(params, :session, session), %{}) do
            {:ok, result} ->
              Actions.emit_completed(__MODULE__, %{url: url})
              {:ok, result}

            {:error, reason} ->
              Actions.emit_failed(__MODULE__, reason)
              {:error, Browser.format_error(reason)}
          end
        end)
      end
    end)
  end
end

defmodule Arbor.Actions.Browser.Back do
  @moduledoc """
  Navigate back in browser history.

  Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
  the facade-issued envelope fails closed and does not call `jido_browser`.
  The authorized path is `Arbor.Actions.authorize_and_execute/4`, then the
  existing Back implementation. This surface never falls back to
  `Arbor.Shell.authorize_and_execute/3`.
  """

  use Jido.Action,
    name: "browser_back",
    description: "Navigate back in browser history",
    category: "browser",
    tags: ["browser", "navigation", "history"],
    schema: [
      timeout: [type: :integer, doc: "Timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_authorized_principal(context, __MODULE__, fn ->
      Browser.with_session(context, fn session ->
        Actions.emit_started(__MODULE__, %{})

        case JidoBrowser.Actions.Back.run(Map.put(params, :session, session), %{}) do
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

defmodule Arbor.Actions.Browser.Forward do
  @moduledoc """
  Navigate forward in browser history.

  Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
  the facade-issued envelope fails closed and does not call `jido_browser`.
  The authorized path is `Arbor.Actions.authorize_and_execute/4`, then the
  existing Forward implementation. This surface never falls back to
  `Arbor.Shell.authorize_and_execute/3`.
  """

  use Jido.Action,
    name: "browser_forward",
    description: "Navigate forward in browser history",
    category: "browser",
    tags: ["browser", "navigation", "history"],
    schema: [
      timeout: [type: :integer, doc: "Timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_authorized_principal(context, __MODULE__, fn ->
      Browser.with_session(context, fn session ->
        Actions.emit_started(__MODULE__, %{})

        case JidoBrowser.Actions.Forward.run(Map.put(params, :session, session), %{}) do
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

defmodule Arbor.Actions.Browser.Reload do
  @moduledoc """
  Reload the current page.

  Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
  the facade-issued envelope fails closed and does not call `jido_browser`.
  The authorized path is `Arbor.Actions.authorize_and_execute/4`, then the
  existing Reload implementation. This surface never falls back to
  `Arbor.Shell.authorize_and_execute/3`.
  """

  use Jido.Action,
    name: "browser_reload",
    description: "Reload the current browser page",
    category: "browser",
    tags: ["browser", "navigation", "reload"],
    schema: [
      timeout: [type: :integer, doc: "Timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_authorized_principal(context, __MODULE__, fn ->
      Browser.with_session(context, fn session ->
        Actions.emit_started(__MODULE__, %{})

        case JidoBrowser.Actions.Reload.run(Map.put(params, :session, session), %{}) do
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

defmodule Arbor.Actions.Browser.GetUrl do
  @moduledoc """
  Get the current page URL.

  Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
  the facade-issued envelope fails closed and does not call `jido_browser`.
  The authorized path is `Arbor.Actions.authorize_and_execute/4`, then the
  existing GetUrl implementation. This surface never falls back to
  `Arbor.Shell.authorize_and_execute/3`.
  """

  use Jido.Action,
    name: "browser_get_url",
    description: "Get the current page URL",
    category: "browser",
    tags: ["browser", "navigation", "url"],
    schema: [
      timeout: [type: :integer, doc: "Timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_authorized_principal(context, __MODULE__, fn ->
      Browser.with_session(context, fn session ->
        Actions.emit_started(__MODULE__, %{})

        case JidoBrowser.Actions.GetUrl.run(Map.put(params, :session, session), %{}) do
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

defmodule Arbor.Actions.Browser.GetTitle do
  @moduledoc """
  Get the current page title.

  Requires `Arbor.Actions.authorized_principal/2`. Direct `run/2` without
  the facade-issued envelope fails closed and does not call `jido_browser`.
  The authorized path is `Arbor.Actions.authorize_and_execute/4`, then the
  existing GetTitle implementation. This surface never falls back to
  `Arbor.Shell.authorize_and_execute/3`.
  """

  use Jido.Action,
    name: "browser_get_title",
    description: "Get the current page title",
    category: "browser",
    tags: ["browser", "navigation", "title"],
    schema: [
      timeout: [type: :integer, doc: "Timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  @impl true
  def run(params, context) do
    Browser.with_authorized_principal(context, __MODULE__, fn ->
      Browser.with_session(context, fn session ->
        Actions.emit_started(__MODULE__, %{})

        case JidoBrowser.Actions.GetTitle.run(Map.put(params, :session, session), %{}) do
          {:ok, result} ->
            Actions.emit_completed(__MODULE__, %{title: result[:title]})
            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, Browser.format_error(reason)}
        end
      end)
    end)
  end
end
