defmodule Arbor.Contracts.Agent do
  @moduledoc """
  Composite agent view — assembles all 4 domains into a unified structure.

  This struct is a read-only assembly, never stored or mutated as a whole.
  Each domain has its own lifecycle, persistence, and CRC core.

  ## Domains

  - **Authority**: Who you are, what you can do, how trusted (Identity + Character + Trust + Security)
  - **Config**: How you're set up, where you're running (Config + Runtime)
  - **Context**: What you know, what's happening now (Session + Memory)
  - **Telemetry**: How you're performing (Metrics — externalized to ETS)

  ## Assembly

  The composite is assembled lazily — Context and Telemetry are loaded on demand:

      Agent.assemble(agent_id, load: [:context, :telemetry])

  For quick inspection (the "2am rule"):

      Agent.summary(agent_id)

  ## CRC Pattern

  Each domain has its own pure functional core:

      # Construct
      Authority.new(agent_id, public_key, character)
      Config.new(model_config)
      Context.new(session_config)
      Telemetry.new(agent_id)

      # Reduce (pure transformations)
      Authority.Trust.record_approval(trust, uri)
      Context.Session.append(session, message)
      Telemetry.record_turn(telemetry, usage)

      # Convert (for output/display)
      Authority.show(authority)           # dashboard summary
      Authority.for_peer(authority)       # for other agents
      Context.Session.for_llm(session)    # messages for LLM
      Telemetry.show_dashboard(telemetry) # metrics panel
  """

  alias Arbor.Contracts.Agent.{Authority, Config, Context, Telemetry}

  @type t :: %__MODULE__{
          authority: Authority.t() | :not_loaded,
          config: Config.t() | :not_loaded,
          context: Context.t() | :not_loaded,
          telemetry: Telemetry.t() | :not_loaded
        }

  defstruct [
    authority: :not_loaded,
    config: :not_loaded,
    context: :not_loaded,
    telemetry: :not_loaded
  ]
end
