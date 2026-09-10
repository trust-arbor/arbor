defmodule Arbor.Agent.SimpleAgent do
  @moduledoc """
  Minimal tool-calling agent loop.

  Implements the simplest thing that works — the Claude Code loop:

      prompt → LLM (with tools) → tool calls? → execute → results back → LLM → repeat until text

  Every tool call is tracked with name, args, result, and timing for eval comparison.

  ## Usage

      {:ok, result} = SimpleAgent.run("Read mix.exs and tell me the app name",
        provider: :openrouter,
        model: "openai/gpt-oss-120b:free",
        working_dir: "/path/to/project"
      )

      result.text       # "The app name is :my_app"
      result.turns      # 2
      result.tool_calls # [%{turn: 1, name: "file_read", ...}]
  """

  alias Arbor.Agent.ContextCompactor
  alias Arbor.LLM
  alias Arbor.LLM.{Message, Response, Tool}

  require Logger

  @default_max_turns 25
  @max_result_length 4000

  @coding_tools [
    Arbor.Actions.File.Read,
    Arbor.Actions.File.Write,
    Arbor.Actions.File.Edit,
    Arbor.Actions.File.List,
    Arbor.Actions.File.Glob,
    Arbor.Actions.File.Search,
    Arbor.Actions.File.Exists,
    Arbor.Actions.Shell.Execute,
    Arbor.Actions.Git.Status,
    Arbor.Actions.Git.Diff,
    Arbor.Actions.Git.Log,
    Arbor.Actions.Git.Commit
  ]

  @memory_tools [
    Arbor.Actions.Memory.Remember,
    Arbor.Actions.Memory.Recall,
    Arbor.Actions.Memory.Connect,
    Arbor.Actions.Memory.Reflect,
    Arbor.Actions.MemoryIdentity.AddInsight,
    Arbor.Actions.MemoryIdentity.ReadSelf,
    Arbor.Actions.MemoryIdentity.IntrospectMemory
  ]

  @relationship_tools [
    Arbor.Actions.Relationship.Get,
    Arbor.Actions.Relationship.Save,
    Arbor.Actions.Relationship.Moment,
    Arbor.Actions.Relationship.Browse,
    Arbor.Actions.Relationship.Summarize
  ]

  @relational_tools @memory_tools ++ @relationship_tools

  @default_tools @coding_tools

  @type tool_entry :: %{
          turn: pos_integer(),
          name: String.t(),
          args: map(),
          result: String.t(),
          duration_ms: non_neg_integer(),
          timestamp: DateTime.t()
        }

  @type result :: %{
          text: String.t() | nil,
          turns: non_neg_integer(),
          tool_calls: [tool_entry()],
          model: String.t(),
          usage: map(),
          status: :completed | :max_turns | :context_overflow
        }

  @doc """
  Run the agent loop on a task.

  ## Options

    * `:model` - Model ID (default: `"openai/gpt-oss-120b:free"`)
    * `:provider` - Provider atom (default: `:openrouter`)
    * `:max_turns` - Maximum LLM round-trips (default: 25)
    * `:timeout` - Deadline in milliseconds for each loop model call (LLM facade default)
    * `:max_response_bytes` - Narrow the LLM facade's response ceiling for each loop model call
    * `:tools` - List of action modules (default: 12 coding tools)
    * `:tool_preset` - Preset tool set: `:coding`, `:memory`, `:relational`, `:all` (overrides `:tools`)
    * `:system_prompt` - Override system prompt
    * `:working_dir` - Working directory for file/shell operations
    * `:agent_id` - Agent identity for authorization (default: `"system"`)
    * `:context_management` - Context management mode: `:none`, `:heuristic`, `:full` (default: `:none`)
    * `:effective_window` - Override effective context window in tokens
    * `:enable_llm_compaction` - Enable LLM narrative summaries (default: false)

  Model calls use `Arbor.LLM` and its configured default client. The loop owns
  tool execution; the facade performs one model step per turn. `usage` adds
  numeric counters from completed model calls and retains the latest value for
  provider detail fields. Compaction calls are not included in these counters.
  """
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(task, opts \\ []) do
    provider =
      Keyword.get_lazy(opts, :provider, fn -> Arbor.Agent.LLMDefaults.default_provider() end)

    model = Keyword.get_lazy(opts, :model, fn -> Arbor.Agent.LLMDefaults.default_model() end)
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    agent_id = Keyword.get(opts, :agent_id, "system")

    action_modules =
      case Keyword.get(opts, :tool_preset) do
        :coding -> @coding_tools
        :memory -> @memory_tools
        :relational -> @relational_tools
        :all -> @coding_tools ++ @relational_tools
        nil -> Keyword.get(opts, :tools, @default_tools)
        _other -> Keyword.get(opts, :tools, @default_tools)
      end

    context_mode = Keyword.get(opts, :context_management, :full)

    system_prompt =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        default_system_prompt(working_dir)
      end)

    # Describe tools without giving the LLM facade ownership of their execution.
    tools = build_tools(action_modules)

    messages = [
      %{role: :system, content: system_prompt},
      %{role: :user, content: task}
    ]

    compactor =
      if context_mode != :none do
        # Seed compactor with initial messages so llm_messages/1 includes them
        Enum.reduce(
          messages,
          ContextCompactor.new(
            model: model,
            effective_window: Keyword.get(opts, :effective_window),
            enable_llm_compaction: context_mode == :full
          ),
          &ContextCompactor.append(&2, &1)
        )
      end

    state = %{
      turn: 0,
      max_turns: max_turns,
      model: model,
      provider: provider,
      llm_opts: Keyword.take(opts, [:timeout, :max_response_bytes]),
      working_dir: working_dir,
      agent_id: agent_id,
      tool_history: [],
      usage: %{},
      compactor: compactor
    }

    loop(messages, tools, state)
  end

  # ── Loop ──────────────────────────────────────────────────────────

  defp loop(_messages, _tools, %{turn: turn, max_turns: max} = state) when turn >= max do
    {:ok, build_result(nil, state, :max_turns)}
  end

  defp loop(messages, tools, state) do
    # When using context management, use the compactor's projected view for LLM calls
    messages_for_llm =
      if state.compactor do
        ContextCompactor.llm_messages(state.compactor)
      else
        messages
      end

    case llm_call(messages_for_llm, tools, state) do
      {:ok, response} ->
        state = %{state | usage: merge_usage(state.usage, response.usage)}
        classified = classify_response(response)

        case classified.type do
          :tool_calls ->
            {result_strings, new_history} = execute_all(classified.tool_calls, state)

            # Build assistant message with tool calls
            assistant_msg = %{
              role: :assistant,
              content: classified.text || "",
              tool_calls: classified.tool_calls
            }

            # Build tool result messages
            tool_msgs =
              Enum.zip(classified.tool_calls, result_strings)
              |> Enum.map(fn {tc, result_str} ->
                %{
                  role: :tool,
                  tool_call_id: tc.id,
                  name: tc_name(tc),
                  content: result_str
                }
              end)

            new_messages = messages ++ [assistant_msg | tool_msgs]

            # Update compactor if active
            old_compression_count =
              if state.compactor, do: Map.get(state.compactor, :compression_count, 0), else: 0

            new_compactor =
              if state.compactor do
                compacted =
                  [assistant_msg | tool_msgs]
                  |> Enum.reduce(state.compactor, &ContextCompactor.append(&2, &1))
                  |> ContextCompactor.maybe_compact()

                # Record compaction telemetry if compaction occurred
                if Map.get(compacted, :compression_count, 0) > old_compression_count do
                  utilization =
                    if Map.get(compacted, :effective_window, 0) > 0,
                      do: Map.get(compacted, :token_count, 0) / compacted.effective_window,
                      else: 0.0

                  maybe_record_compaction_telemetry(state.agent_id, utilization)
                end

                compacted
              end

            new_state = %{
              state
              | turn: state.turn + 1,
                tool_history: state.tool_history ++ new_history,
                compactor: new_compactor || state.compactor
            }

            loop(new_messages, tools, new_state)

          :final_answer ->
            {:ok, build_result(classified.text, %{state | turn: state.turn + 1}, :completed)}
        end

      {:error, reason} ->
        reason_str = inspect(reason)

        if String.contains?(reason_str, "context length") or
             String.contains?(reason_str, "maximum context") do
          # Context window overflow — return partial result instead of error
          Logger.warning(
            "Context overflow at turn #{state.turn}: #{String.slice(reason_str, 0, 200)}"
          )

          {:ok, build_result(nil, state, :context_overflow)}
        else
          {:error, reason}
        end
    end
  end

  # ── LLM Call ──────────────────────────────────────────────────────

  defp llm_call(messages, tools, state) do
    LLM.generate(
      state.llm_opts ++
        [
          provider: to_string(state.provider),
          model: state.model,
          messages: Enum.map(messages, &to_llm_message/1),
          tools: tools,
          max_tool_rounds: 0,
          max_tokens: 16_384,
          temperature: 0.3
        ]
    )
  end

  defp to_llm_message(%{role: :assistant} = message) do
    content =
      [%{kind: :text, text: Map.get(message, :content) || ""}] ++
        Map.get(message, :tool_calls, [])

    %Message{role: :assistant, content: content}
  end

  defp to_llm_message(%{role: :tool} = message) do
    %Message{
      role: :tool,
      content: message.content,
      metadata: Map.take(message, [:tool_call_id, :name])
    }
  end

  defp to_llm_message(message), do: %Message{role: message.role, content: message.content}

  # ── Tool Execution ───────────────────────────────────────────────

  defp execute_all(tool_calls, state) do
    Enum.map_reduce(tool_calls, [], fn tc, history ->
      name = tc_name(tc)
      args = tc_args(tc)
      start = System.monotonic_time(:millisecond)
      result = execute_tool(name, args, state)
      duration = System.monotonic_time(:millisecond) - start
      result_str = format_result(result)

      entry = %{
        turn: state.turn + 1,
        name: name,
        args: args,
        result: truncate(result_str, @max_result_length),
        duration_ms: duration,
        timestamp: DateTime.utc_now()
      }

      {result_str, history ++ [entry]}
    end)
  end

  defp execute_tool(name, args, state) do
    # Check if security stack (CapabilityStore) is running — if not, skip
    # authorize_and_execute entirely and call action modules directly.
    security_available? =
      Process.whereis(Arbor.Security.CapabilityStore) != nil

    if security_available? do
      executor_mod = Module.concat([:Arbor, :Orchestrator, :ActionsExecutor])

      try do
        if Code.ensure_loaded?(executor_mod) do
          apply(executor_mod, :execute, [
            name,
            args,
            state.working_dir,
            [agent_id: state.agent_id]
          ])
        else
          direct_execute(name, args, state)
        end
      catch
        :exit, {:noproc, _} ->
          direct_execute(name, args, state)
      end
    else
      direct_execute(name, args, state)
    end
  end

  # Direct action execution — bypasses authorization (for tests or when security stack unavailable)
  defp direct_execute(name, args, state) do
    case Arbor.Actions.name_to_module(name) do
      {:ok, module} ->
        safe_args =
          args
          |> atomize_known_keys(module)
          |> maybe_inject_workdir(state.working_dir)

        case module.run(safe_args, %{}) do
          {:ok, result} -> {:ok, format_action_result(result)}
          {:error, reason} -> {:error, "Action #{name} failed: #{inspect(reason)}"}
        end

      {:error, _} ->
        {:error, "Unknown tool: #{name}"}
    end
  end

  defp maybe_inject_workdir(args, _working_dir), do: args

  defp format_action_result(result) when is_binary(result), do: result

  defp format_action_result(result) when is_map(result) do
    case Jason.encode(result) do
      {:ok, json} -> json
      _ -> inspect(result)
    end
  end

  defp format_action_result(result), do: inspect(result)

  # ── Response Classification ──────────────────────────────────────

  defp classify_response(%Response{} = response) do
    tool_calls =
      Enum.filter(response.content_parts, fn
        %{kind: :tool_call} -> true
        _ -> false
      end)

    %{
      type:
        if(tool_calls != [] or response.finish_reason == :tool_calls,
          do: :tool_calls,
          else: :final_answer
        ),
      text: response.text,
      tool_calls: tool_calls
    }
  end

  # ── Tool Building ───────────────────────────────────────────────

  defp build_tools(action_modules) do
    adapter_mod = Module.concat([:Jido, :AI, :ToolAdapter])

    definitions =
      if Code.ensure_loaded?(adapter_mod) do
        apply(adapter_mod, :from_actions, [action_modules])
      else
        Enum.map(action_modules, fn mod ->
          if function_exported?(mod, :to_tool, 0) do
            mod.to_tool()
          end
        end)
        |> Enum.reject(&is_nil/1)
      end

    Enum.map(definitions, fn definition ->
      %Tool{
        name: definition.name,
        description: definition.description,
        input_schema:
          Map.get(definition, :parameter_schema) || Map.get(definition, :parameters_schema) || %{}
      }
    end)
  end

  # ── Helpers ──────────────────────────────────────────────────────

  # The LLM facade returns canonical tool-call content parts.
  defp tc_name(%{name: name}), do: name

  defp tc_args(%{arguments: args}), do: ensure_map(args)

  defp ensure_map(args) when is_map(args), do: args

  defp ensure_map(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"raw" => args}
    end
  end

  defp ensure_map(_), do: %{}

  defp default_system_prompt(working_dir) do
    """
    You are a coding agent. You have tools to read, write, edit, and search files, \
    run shell commands, and use git. Use these tools to complete the task.

    When you've completed the task, explain what you did.

    Working directory: #{working_dir}
    """
  end

  defp merge_usage(previous, current) do
    Map.merge(previous, current, fn _key, old, new ->
      cond do
        is_number(old) and is_number(new) -> old + new
        is_nil(new) -> old
        true -> new
      end
    end)
  end

  defp build_result(text, state, status) do
    base = %{
      text: text,
      turns: state.turn,
      tool_calls: state.tool_history,
      model: state.model,
      usage: state.usage,
      status: status
    }

    if state.compactor do
      Map.merge(base, %{
        context_stats: ContextCompactor.stats(state.compactor),
        full_transcript: state.compactor.full_transcript
      })
    else
      base
    end
  end

  defp format_result({:ok, result}) when is_binary(result), do: result
  defp format_result({:ok, result}) when is_map(result), do: Jason.encode!(result)
  defp format_result({:ok, result}), do: inspect(result)
  defp format_result({:error, reason}) when is_binary(reason), do: "ERROR: #{reason}"
  defp format_result({:error, reason}), do: "ERROR: #{inspect(reason)}"
  defp format_result(other), do: inspect(other)

  defp truncate(str, max) when byte_size(str) <= max, do: str

  defp truncate(str, max) do
    String.slice(str, 0, max) <> "\n... (truncated)"
  end

  defp atomize_known_keys(args, _action_module) do
    # LLM sends string keys. Action schemas use atom keys.
    # Use to_existing_atom for safety — all Jido action schema keys
    # are defined at compile time as atoms.
    Map.new(args, fn {k, v} ->
      if is_binary(k) do
        try do
          {String.to_existing_atom(k), v}
        rescue
          ArgumentError -> {k, v}
        end
      else
        {k, v}
      end
    end)
  end

  defp maybe_record_compaction_telemetry(agent_id, utilization) do
    Arbor.Common.AgentTelemetry.Store.record_compaction(agent_id, utilization)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
