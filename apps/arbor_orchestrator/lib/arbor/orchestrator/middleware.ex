defmodule Arbor.Orchestrator.Middleware do
  @moduledoc """
  Behaviour for pipeline execution middleware.

  Middleware wraps node execution with before/after hooks, similar to
  Phoenix Plug. Each middleware receives a Token struct, can inspect
  or modify it, and either pass through or halt execution.

  Middleware is composable — multiple middleware run in order for
  before_node, and in reverse order for after_node.

  ## Usage

      defmodule MyMiddleware do
        use Arbor.Orchestrator.Middleware

        @impl true
        def before_node(token) do
          # inspect/modify token, or halt
          token
        end

        @impl true
        def after_node(token) do
          # inspect/modify outcome
          token
        end
      end
  """

  alias Arbor.Orchestrator.Middleware.Token

  @callback before_node(Token.t()) :: Token.t()
  @callback after_node(Token.t()) :: Token.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Arbor.Orchestrator.Middleware

      alias Arbor.Orchestrator.Middleware.Token

      @impl true
      def before_node(token), do: token

      @impl true
      def after_node(token), do: token

      defoverridable before_node: 1, after_node: 1
    end
  end

  @doc "Halts the token with the given reason."
  @spec halt(Token.t(), String.t()) :: Token.t()
  def halt(%Token{} = token, reason) do
    Token.halt(token, reason)
  end
end
