defmodule Arbor.Orchestrator.Middleware.Token do
  @moduledoc """
  Execution context struct that flows through the middleware chain.

  The Token carries all the information a middleware needs to inspect
  or modify pipeline execution. It is analogous to Plug.Conn.
  """

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node

  @type t :: %__MODULE__{
          node: Node.t(),
          context: Context.t(),
          graph: Graph.t(),
          logs_root: String.t(),
          outcome: Outcome.t() | nil,
          halted: boolean(),
          halt_reason: String.t(),
          assigns: map()
        }

  defstruct [
    :node,
    :context,
    :graph,
    :logs_root,
    outcome: nil,
    halted: false,
    halt_reason: "",
    assigns: %{}
  ]

  @doc "Puts a value into `token.assigns` under the given key."
  @spec assign(t(), atom() | String.t(), any()) :: t()
  def assign(%__MODULE__{assigns: assigns} = token, key, value) do
    %{token | assigns: Map.put(assigns, key, value)}
  end

  @doc "Halts middleware execution with the given reason."
  @spec halt(t(), String.t()) :: t()
  def halt(%__MODULE__{} = token, reason) do
    %{token | halted: true, halt_reason: reason}
  end

  @doc "Halts middleware execution with the given reason and sets a custom outcome."
  @spec halt(t(), String.t(), Outcome.t()) :: t()
  def halt(%__MODULE__{} = token, reason, %Outcome{} = outcome) do
    %{token | halted: true, halt_reason: reason, outcome: outcome}
  end
end
