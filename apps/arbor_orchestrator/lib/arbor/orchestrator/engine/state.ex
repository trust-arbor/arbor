defmodule Arbor.Orchestrator.Engine.State do
  @moduledoc "Bundles all loop-carried state for the Engine's recursive execution loop."

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Edge

  @type t :: %__MODULE__{
          graph: Graph.t(),
          node_id: String.t() | nil,
          incoming_edge: Edge.t() | nil,
          context: Context.t(),
          logs_root: String.t(),
          max_steps: non_neg_integer(),
          completed: [String.t()],
          retries: %{String.t() => non_neg_integer()},
          outcomes: %{String.t() => Outcome.t()},
          pending: [{String.t(), Edge.t() | nil}],
          opts: keyword(),
          pipeline_started_at: integer(),
          tracking: map()
        }

  defstruct [
    :graph,
    :node_id,
    :incoming_edge,
    :context,
    :logs_root,
    :max_steps,
    :pipeline_started_at,
    completed: [],
    retries: %{},
    outcomes: %{},
    pending: [],
    opts: [],
    tracking: %{node_durations: %{}, content_hashes: %{}}
  ]
end
