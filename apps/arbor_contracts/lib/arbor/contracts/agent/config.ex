defmodule Arbor.Contracts.Agent.Config do
  @moduledoc """
  Configuration domain — how the agent is set up and where it's running.

  Lifecycle: static at boot, rarely changes. Runtime rebuilt on start.
  Persistence: config is durable/cached, runtime is never persisted.
  """

  alias Arbor.Contracts.Agent.Config.Runtime

  @type execution_mode :: :session | :direct | :acp
  @type tool_exposure :: :full | :progressive | :minimal

  @type generation_params :: %{
          optional(:temperature) => float(),
          optional(:top_p) => float(),
          optional(:max_tokens) => pos_integer(),
          optional(:max_turns) => pos_integer()
        }

  @type heartbeat_config :: %{
          enabled: boolean(),
          interval_ms: pos_integer(),
          model: String.t() | nil
        }

  @type t :: %__MODULE__{
          provider: atom(),
          model: String.t(),
          model_profile: map(),
          system_prompt: String.t(),
          generation_params: generation_params(),
          tools: [map()],
          tool_exposure: tool_exposure(),
          heartbeat: heartbeat_config(),
          execution_mode: execution_mode(),
          auto_start: boolean(),
          runtime: Runtime.t() | nil
        }

  @enforce_keys [:provider, :model]
  defstruct [
    :provider,
    :model,
    :system_prompt,
    :runtime,
    model_profile: %{},
    generation_params: %{},
    tools: [],
    tool_exposure: :full,
    heartbeat: %{enabled: true, interval_ms: 30_000, model: nil},
    execution_mode: :session,
    auto_start: false
  ]
end

defmodule Arbor.Contracts.Agent.Config.Runtime do
  @moduledoc """
  Volatile runtime state — process references and device capabilities.

  NEVER persisted. Rebuilt on agent start. Dies with the process.
  """

  @type device_capabilities :: %{
          tee: boolean(),
          npu: map() | nil,
          gpu: map() | nil
        }

  @type t :: %__MODULE__{
          supervisor_pid: pid() | nil,
          host_pid: pid() | nil,
          session_pid: pid() | nil,
          executor_pid: pid() | nil,
          node: atom(),
          device_capabilities: device_capabilities(),
          started_at: DateTime.t()
        }

  defstruct [
    :supervisor_pid,
    :host_pid,
    :session_pid,
    :executor_pid,
    :started_at,
    node: :nonode@nohost,
    device_capabilities: %{tee: false, npu: nil, gpu: nil}
  ]
end
