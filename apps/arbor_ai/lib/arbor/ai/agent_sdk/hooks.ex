defmodule Arbor.AI.AgentSDK.Hooks do
  @moduledoc """
  Hook callbacks for intercepting tool calls.

  Hooks allow programmatic control over tool execution, replacing shell-based
  hooks with native Elixir callbacks. This matches the hook functionality from
  the official Python and TypeScript SDKs.

  ## Usage

      {:ok, response} = Arbor.AI.AgentSDK.query("Do something",
        hooks: %{
          pre_tool_use: fn tool_name, tool_input, context ->
            if tool_name == "Bash" and dangerous?(tool_input) do
              {:deny, "Blocked dangerous command"}
            else
              :allow
            end
          end,
          post_tool_use: fn tool_name, tool_input, result, context ->
            Logger.info("Tool \#{tool_name} completed")
            :ok
          end,
          on_message: fn message, context ->
            Logger.debug("Message: \#{inspect(message)}")
            :ok
          end
        }
      )

  ## Hook Types

  - `pre_tool_use` — Called before tool execution
    - Return `:allow` to proceed
    - Return `{:deny, reason}` to block the tool call
    - Return `{:modify, new_input}` to change the tool input

  - `post_tool_use` — Called after tool execution
    - For logging, signals, metrics
    - Return value ignored

  - `on_message` — Called for each message from Claude
    - For logging, streaming, UI updates
    - Return value ignored
  """

  @type hook_context :: %{
          session_id: String.t() | nil,
          cwd: String.t(),
          model: String.t() | nil
        }

  @type pre_hook_result ::
          :allow
          | :deny
          | {:deny, String.t()}
          | {:modify, map()}

  @type pre_tool_hook ::
          (tool_name :: String.t(), tool_input :: map(), hook_context() -> pre_hook_result())

  @type post_tool_hook ::
          (tool_name :: String.t(), tool_input :: map(), result :: term(), hook_context() ->
             :ok)

  @type message_hook :: (message :: map(), hook_context() -> :ok)

  @type hooks :: %{
          optional(:pre_tool_use) => pre_tool_hook() | [pre_tool_hook()],
          optional(:post_tool_use) => post_tool_hook() | [post_tool_hook()],
          optional(:on_message) => message_hook() | [message_hook()]
        }

  @doc """
  Run pre-tool-use hooks. Returns the final decision.

  When multiple hooks are provided as a list, they run as a chain:
  - `:allow` continues to the next hook
  - `{:modify, new_input}` continues with modified input
  - `:deny` or `{:deny, reason}` stops the chain immediately
  """
  @spec run_pre_hooks(hooks(), String.t(), map(), hook_context()) ::
          {:allow, map()} | {:deny, String.t()}
  def run_pre_hooks(hooks, tool_name, tool_input, context) do
    case Map.get(hooks, :pre_tool_use) do
      nil ->
        {:allow, tool_input}

      hook when is_function(hook) ->
        process_pre_result(hook.(tool_name, tool_input, context), tool_input)

      hook_list when is_list(hook_list) ->
        run_pre_hook_chain(hook_list, tool_name, tool_input, context)
    end
  end

  @doc """
  Run post-tool-use hooks.
  """
  @spec run_post_hooks(hooks(), String.t(), map(), term(), hook_context()) :: :ok
  def run_post_hooks(hooks, tool_name, tool_input, result, context) do
    case Map.get(hooks, :post_tool_use) do
      nil ->
        :ok

      hook when is_function(hook) ->
        hook.(tool_name, tool_input, result, context)
        :ok

      hook_list when is_list(hook_list) ->
        Enum.each(hook_list, & &1.(tool_name, tool_input, result, context))
        :ok
    end
  end

  @doc """
  Run on-message hooks.
  """
  @spec run_message_hooks(hooks(), map(), hook_context()) :: :ok
  def run_message_hooks(hooks, message, context) do
    case Map.get(hooks, :on_message) do
      nil ->
        :ok

      hook when is_function(hook) ->
        hook.(message, context)
        :ok

      hook_list when is_list(hook_list) ->
        Enum.each(hook_list, & &1.(message, context))
        :ok
    end
  end

  @doc """
  Build a hook context from the current state.
  """
  @spec build_context(keyword()) :: hook_context()
  def build_context(opts) do
    %{
      session_id: Keyword.get(opts, :session_id),
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      model: Keyword.get(opts, :model) |> maybe_to_string()
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp run_pre_hook_chain([], _name, input, _ctx), do: {:allow, input}

  defp run_pre_hook_chain([hook | rest], name, input, ctx) do
    case process_pre_result(hook.(name, input, ctx), input) do
      {:allow, current_input} ->
        run_pre_hook_chain(rest, name, current_input, ctx)

      {:deny, _reason} = deny ->
        deny
    end
  end

  defp process_pre_result(:allow, input), do: {:allow, input}
  defp process_pre_result(:deny, _input), do: {:deny, "Tool call denied by hook"}
  defp process_pre_result({:deny, reason}, _input), do: {:deny, reason}
  defp process_pre_result({:modify, new_input}, _input), do: {:allow, new_input}

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(val) when is_atom(val), do: Atom.to_string(val)
  defp maybe_to_string(val) when is_binary(val), do: val
end
