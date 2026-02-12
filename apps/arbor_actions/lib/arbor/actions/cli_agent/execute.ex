defmodule Arbor.Actions.CliAgent.Execute do
  @moduledoc """
  Execute a one-shot prompt through a CLI-based coding agent.

  Dispatches to an agent-specific adapter based on the `agent` parameter.
  Each adapter handles binary resolution, argument building, output parsing,
  and permission flag formatting.

  ## Parameters

  | Name | Type | Required | Description |
  |------|------|----------|-------------|
  | `agent` | string | yes | CLI agent: "claude", "opencode", "codex", "gemini", "qwen" |
  | `prompt` | string | yes | The prompt to send |
  | `model` | string | no | Model name (agent-specific) |
  | `system_prompt` | string | no | System prompt for the session |
  | `working_dir` | string | no | Working directory for execution |
  | `timeout` | integer | no | Timeout in ms (default: 300000) |
  | `max_thinking_tokens` | integer | no | Thinking budget (default: 10000) |
  | `session_id` | string | no | Resume a previous session |
  | `allowed_tools` | list | no | Explicit tool allowlist override |
  | `disallowed_tools` | list | no | Explicit tool denylist override |

  ## Returns

  - `text` - The response text
  - `session_id` - Session ID for resumption
  - `model` - Model used
  - `input_tokens` - Input token count
  - `output_tokens` - Output token count
  - `cost_usd` - Cost in USD (nil for free agents)
  - `is_error` - Whether the agent reported an error
  - `duration_ms` - Execution duration in milliseconds
  - `agent` - Which CLI agent was used
  """

  use Jido.Action,
    name: "cli_agent_execute",
    description: "Execute a one-shot prompt through a CLI-based coding agent",
    category: "cli_agent",
    tags: ["cli", "agent", "llm", "agentic"],
    schema: [
      agent: [
        type: :string,
        required: true,
        doc: "CLI agent to use: claude, opencode, codex, gemini, qwen"
      ],
      prompt: [
        type: :string,
        required: true,
        doc: "The prompt to send to the CLI agent"
      ],
      model: [
        type: :string,
        doc: "Model to use (agent-specific)"
      ],
      system_prompt: [
        type: :string,
        doc: "System prompt for the session"
      ],
      working_dir: [
        type: :string,
        doc: "Working directory for execution"
      ],
      timeout: [
        type: :non_neg_integer,
        default: 300_000,
        doc: "Timeout in milliseconds"
      ],
      max_thinking_tokens: [
        type: :non_neg_integer,
        default: 10_000,
        doc: "Thinking token budget"
      ],
      session_id: [
        type: :string,
        doc: "Resume a previous session"
      ],
      allowed_tools: [
        type: {:list, :string},
        doc: "Explicit tool allowlist (overrides capability mapping)"
      ],
      disallowed_tools: [
        type: {:list, :string},
        doc: "Explicit tool denylist (overrides capability mapping)"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.CliAgent.Adapters

  @spec taint_roles() :: %{atom() => :control | :data}
  def taint_roles do
    %{
      agent: :control,
      prompt: :control,
      model: :control,
      system_prompt: :control,
      working_dir: :control,
      timeout: :data,
      max_thinking_tokens: :data,
      session_id: :control,
      allowed_tools: :control,
      disallowed_tools: :control
    }
  end

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, context) do
    case Adapters.resolve(params.agent) do
      {:ok, adapter} ->
        Actions.emit_started(__MODULE__, params)

        case adapter.execute(params, context) do
          {:ok, result} ->
            result = Map.put(result, :agent, params.agent)
            Actions.emit_completed(__MODULE__, result)
            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end
end
