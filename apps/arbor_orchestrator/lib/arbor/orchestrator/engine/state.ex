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
          tracking: map(),
          # Process-local lifecycle tracking via RunState CRC core.
          # The Engine owns this state directly — no external GenServer
          # dependency. Written to the :arbor_pipeline_runs ETS table
          # on each transition for dashboard/Facade visibility.
          run_state: Arbor.Orchestrator.RunState.Core.t() | nil
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
    run_state: nil,
    tracking: %{
      node_durations: %{},
      content_hashes: %{},
      pending_intents: %{},
      execution_digests: %{}
    }
  ]
end
