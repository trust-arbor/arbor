defmodule Arbor.Actions.Browser do
  @moduledoc """
  Interactive browser automation actions requiring a browser session.

  Wraps `jido_browser` session-based actions with Arbor security integration
  (taint tracking, signal observability, SSRF prevention on navigation).

  For session-free web actions (read page, search, snapshot URL), see `Arbor.Actions.Web`.

  ## Action Categories

  | Category | Module | Actions |
  |----------|--------|---------|
  | Session | `Browser.StartSession`, `EndSession`, `GetStatus` | Lifecycle management |
  | Navigation | `Browser.Navigate`, `Back`, `Forward`, `Reload`, `GetUrl`, `GetTitle` | Page navigation |
  | Interaction | `Browser.Click`, `Type`, `Hover`, `Focus`, `Scroll`, `SelectOption` | Element interaction |
  | Query | `Browser.Query`, `GetText`, `GetAttribute`, `IsVisible` | Element queries |
  | Content | `Browser.ExtractContent`, `Screenshot`, `Snapshot` | Content extraction |
  | Sync | `Browser.Wait`, `WaitForSelector`, `WaitForNavigation` | Synchronization |
  | Evaluate | `Browser.Evaluate` | JavaScript execution |

  ## Session Threading

  Session flows through context — no global state:

      {:ok, %{session: session}} = Browser.StartSession.run(%{headless: true}, %{})
      {:ok, result} = Browser.Navigate.run(%{url: "https://example.com"}, %{browser_session: session})
      session = result.session  # updated session for next call
  """

  @doc """
  Extract browser session from context.

  Checks `:browser_session`, `:session`, and nested `:tool_context` keys.
  """
  @spec get_session(map()) :: {:ok, term()} | {:error, String.t()}
  def get_session(context) when is_map(context) do
    cond do
      Map.has_key?(context, :browser_session) -> {:ok, context.browser_session}
      Map.has_key?(context, :session) -> {:ok, context.session}
      is_map(context[:tool_context]) -> get_session(context.tool_context)
      true -> {:error, "No browser session in context"}
    end
  end

  def get_session(_), do: {:error, "No browser session in context"}

  @doc """
  Execute a function with a session extracted from context.
  Returns `{:error, "No browser session in context"}` if no session found.
  """
  @spec with_session(map(), (term() -> term())) :: term()
  def with_session(context, fun) do
    case get_session(context) do
      {:ok, session} -> fun.(session)
      error -> error
    end
  end

  @doc false
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(%{message: msg}) when is_binary(msg), do: msg
  def format_error(reason), do: "Browser action failed: #{inspect(reason)}"
end
