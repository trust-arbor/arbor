defmodule Arbor.Actions.Browser.Evaluate do
  @moduledoc """
  Execute arbitrary JavaScript in the browser context.

  This is a high-security action — the `script` parameter has taint role
  `{:control, requires: [:command_injection]}` since it executes code in the browser.
  """

  use Jido.Action,
    name: "browser_evaluate",
    description: "Execute JavaScript in the browser context",
    category: "browser",
    tags: ["browser", "evaluate", "javascript"],
    schema: [
      script: [type: :string, required: true, doc: "JavaScript code to execute"],
      timeout: [type: :integer, doc: "Execution timeout in ms"]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Browser

  def taint_roles, do: %{script: {:control, requires: [:command_injection]}, timeout: :data}

  @impl true
  def run(%{script: _script} = params, context) do
    Browser.with_session(context, fn session ->
      Actions.emit_started(__MODULE__, %{})

      case JidoBrowser.Actions.Evaluate.run(Map.put(params, :session, session), %{}) do
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
