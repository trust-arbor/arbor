defmodule Arbor.Orchestrator.UnifiedLLM.ToolError do
  @moduledoc false

  defexception [:message, :type, :tool_name, :tool_call_id, :retryable, :details]

  @type type ::
          :unknown_tool | :invalid_tool_call | :execution_failed | :tool_timeout | :repair_failed

  @type t :: %__MODULE__{
          message: String.t(),
          type: type(),
          tool_name: String.t() | nil,
          tool_call_id: String.t() | nil,
          retryable: boolean(),
          details: map() | nil
        }

  @impl true
  def exception(opts) do
    %__MODULE__{
      message: Keyword.get(opts, :message, "tool error"),
      type: Keyword.get(opts, :type, :execution_failed),
      tool_name: Keyword.get(opts, :tool_name),
      tool_call_id: Keyword.get(opts, :tool_call_id),
      retryable: Keyword.get(opts, :retryable, false),
      details: Keyword.get(opts, :details)
    }
  end
end
