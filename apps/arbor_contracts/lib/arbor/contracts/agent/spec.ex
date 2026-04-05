defmodule Arbor.Contracts.Agent.Spec do
  @moduledoc """
  Fully resolved agent specification — the single source of truth for what
  an agent should be before any side effects (identity creation, process start,
  persistence) happen.

  All 4 agent creation paths converge on `AgentSpec`:
  - Dashboard "Start Agent" → `Spec.new(opts)`
  - Bootstrap on server start → `Spec.new(opts)`
  - Resume from profile → `Spec.from_profile(profile, model_config)`
  - Direct creation → `Spec.new(opts)`

  ## CRC Pattern

  - **Construct**: `new/1` — resolve template + model + trust + tools into a complete spec
  - **Convert**: `to_profile/3` — spec → Profile for persistence
  - **Convert**: `to_session_opts/2` — spec → keyword list for Session.init
  - **Convert**: `to_lifecycle_opts/1` — spec → keyword list for Lifecycle.create (migration)
  """

  alias Arbor.Agent.Character

  @type trust_tier :: :untrusted | :probationary | :established | :trusted | :veteran | :autonomous
  @type execution_mode :: :session | :direct | :acp

  @type t :: %__MODULE__{
          display_name: String.t(),
          character: Character.t() | nil,
          trust_tier: trust_tier(),
          template: atom() | String.t() | nil,
          template_module: module() | nil,
          provider: atom() | nil,
          model: String.t() | nil,
          system_prompt: String.t() | nil,
          tools: [String.t()],
          initial_goals: [map()],
          initial_capabilities: [map()],
          heartbeat: %{enabled: boolean(), interval_ms: pos_integer(), model: String.t() | nil},
          execution_mode: execution_mode(),
          auto_start: boolean(),
          model_config: map(),
          delegator_id: String.t() | nil,
          tenant_context: term(),
          metadata: map()
        }

  @enforce_keys [:display_name]
  defstruct [
    :display_name,
    :character,
    :template,
    :template_module,
    :provider,
    :model,
    :system_prompt,
    :delegator_id,
    :tenant_context,
    trust_tier: :untrusted,
    tools: [],
    initial_goals: [],
    initial_capabilities: [],
    heartbeat: %{enabled: true, interval_ms: 30_000, model: nil},
    execution_mode: :session,
    auto_start: false,
    model_config: %{},
    metadata: %{}
  ]
end
