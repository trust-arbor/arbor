defmodule Arbor.AI.AgentSDK.Error do
  @moduledoc """
  Structured error types for the Agent SDK.

  Provides specific error types for better error handling, matching the
  error patterns from the official Python and TypeScript SDKs.

  ## Usage

      case Arbor.AI.AgentSDK.query("...") do
        {:ok, response} -> handle_response(response)
        {:error, %Arbor.AI.AgentSDK.Error{type: :cli_not_found}} ->
          IO.puts("Please install Claude CLI")
        {:error, %Arbor.AI.AgentSDK.Error{type: :timeout}} ->
          IO.puts("Query timed out")
        {:error, %Arbor.AI.AgentSDK.Error{} = err} ->
          IO.puts("Error: \#{err.message}")
      end
  """

  defexception [:type, :message, :details]

  @type error_type ::
          :cli_not_found
          | :process_error
          | :json_decode_error
          | :timeout
          | :permission_denied
          | :tool_error
          | :hook_denied
          | :buffer_overflow
          | :prompt_required
          | :not_ready
          | :port_crashed
          | :reconnect_failed

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          details: map()
        }

  @impl true
  def message(%__MODULE__{message: msg}), do: msg

  @doc "CLI executable not found."
  @spec cli_not_found() :: t()
  def cli_not_found do
    %__MODULE__{
      type: :cli_not_found,
      message: "Claude CLI not found. Install with: npm install -g @anthropic-ai/claude-code",
      details: %{}
    }
  end

  @doc "CLI process exited with an error."
  @spec process_error(integer(), String.t()) :: t()
  def process_error(exit_code, stderr \\ "") do
    %__MODULE__{
      type: :process_error,
      message: "Claude CLI exited with code #{exit_code}",
      details: %{exit_code: exit_code, stderr: stderr}
    }
  end

  @doc "Failed to decode JSON from CLI output."
  @spec json_decode_error(String.t(), term()) :: t()
  def json_decode_error(input, reason) do
    %__MODULE__{
      type: :json_decode_error,
      message: "Failed to decode JSON: #{inspect(reason)}",
      details: %{input: String.slice(input, 0..200), reason: reason}
    }
  end

  @doc "Query timed out."
  @spec timeout(pos_integer()) :: t()
  def timeout(timeout_ms) do
    %__MODULE__{
      type: :timeout,
      message: "Query timed out after #{timeout_ms}ms",
      details: %{timeout_ms: timeout_ms}
    }
  end

  @doc "Permission denied by hook or permission mode."
  @spec permission_denied(String.t(), String.t()) :: t()
  def permission_denied(tool_name, reason) do
    %__MODULE__{
      type: :permission_denied,
      message: "Permission denied for tool #{tool_name}: #{reason}",
      details: %{tool: tool_name, reason: reason}
    }
  end

  @doc "Tool execution error."
  @spec tool_error(String.t(), term()) :: t()
  def tool_error(tool_name, reason) do
    %__MODULE__{
      type: :tool_error,
      message: "Tool #{tool_name} failed: #{inspect(reason)}",
      details: %{tool: tool_name, reason: reason}
    }
  end

  @doc "Tool call denied by a pre-tool hook."
  @spec hook_denied(String.t(), String.t()) :: t()
  def hook_denied(tool_name, reason) do
    %__MODULE__{
      type: :hook_denied,
      message: "Hook denied tool #{tool_name}: #{reason}",
      details: %{tool: tool_name, reason: reason}
    }
  end

  @doc "Transport buffer overflow."
  @spec buffer_overflow() :: t()
  def buffer_overflow do
    %__MODULE__{
      type: :buffer_overflow,
      message: "Transport buffer exceeded limit",
      details: %{}
    }
  end

  @doc "No prompt provided."
  @spec prompt_required() :: t()
  def prompt_required do
    %__MODULE__{
      type: :prompt_required,
      message: "A prompt is required",
      details: %{}
    }
  end

  @doc "Transport not yet connected and ready for queries."
  @spec not_ready() :: t()
  def not_ready do
    %__MODULE__{
      type: :not_ready,
      message: "Transport is not ready — Port not yet connected",
      details: %{}
    }
  end

  @doc "Underlying Port process crashed."
  @spec port_crashed(term()) :: t()
  def port_crashed(reason) do
    %__MODULE__{
      type: :port_crashed,
      message: "Port process crashed: #{inspect(reason)}",
      details: %{reason: reason}
    }
  end

  @doc "Exhausted reconnection attempts to the CLI."
  @spec reconnect_failed(non_neg_integer()) :: t()
  def reconnect_failed(attempts) do
    %__MODULE__{
      type: :reconnect_failed,
      message: "Failed to reconnect after #{attempts} attempts",
      details: %{attempts: attempts}
    }
  end
end
