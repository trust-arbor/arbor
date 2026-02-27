defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.Acp do
  @moduledoc """
  Universal ACP provider adapter for the UnifiedLLM system.

  Routes requests to any ACP-compatible coding agent (Claude, Gemini, Codex,
  Goose, OpenCode, etc.) via a single adapter. The target agent is specified
  in `provider_options`:

      %Request{
        provider: "acp",
        model: "sonnet",
        provider_options: %{"agent" => "claude"}
      }

  When no agent is specified, defaults to `:claude`.

  This adapter manages sessions through `Arbor.AI.AcpPool`, which handles
  checkout/checkin lifecycle, idle cleanup, and crash recovery. The pool
  lives in `arbor_ai` — this adapter bridges to it at runtime.
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.{Request, Response}

  require Logger

  @default_agent :claude
  @default_timeout 120_000

  # Runtime bridge targets (arbor_ai is Standalone)
  @pool_mod Arbor.AI.AcpPool
  @session_mod Arbor.AI.AcpSession

  @impl true
  def provider, do: "acp"

  @impl true
  def complete(%Request{} = request, opts \\ []) do
    agent = resolve_agent(request)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    checkout_opts =
      opts
      |> Keyword.put(:model, request.model)
      |> Keyword.put(:timeout, timeout)

    with {:ok, session} <- pool_checkout(agent, checkout_opts),
         {:ok, result} <- session_prompt(session, request, timeout) do
      pool_checkin(session)
      {:ok, format_response(result, request, agent)}
    else
      {:error, reason} ->
        Logger.warning("ACP adapter error (agent=#{agent}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Returns true if the ACP pool is running and available."
  def available? do
    Code.ensure_loaded?(@pool_mod) and is_pid(Process.whereis(@pool_mod))
  end

  @doc "Returns the list of available ACP agents from the session config."
  def available_agents do
    config_mod = Arbor.AI.AcpSession.Config

    if Code.ensure_loaded?(config_mod) do
      try do
        apply(config_mod, :list_providers, [])
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  @impl true
  def runtime_contract do
    alias Arbor.Contracts.AI.{Capabilities, RuntimeContract}

    {:ok, contract} =
      RuntimeContract.new(
        provider: "acp",
        display_name: "ACP (Agent Communication Protocol)",
        type: :cli,
        cli_tools: [],
        capabilities:
          Capabilities.new(
            streaming: true,
            tool_calls: true,
            thinking: true,
            multi_turn: true
          )
      )

    contract
  end

  # -- Private --

  defp resolve_agent(%Request{provider_options: opts}) when is_map(opts) do
    case Map.get(opts, "agent") || Map.get(opts, :agent) do
      nil -> @default_agent
      agent when is_binary(agent) -> safe_to_atom(agent)
      agent when is_atom(agent) -> agent
    end
  end

  defp resolve_agent(_), do: @default_agent

  # Known ACP agent names for safe atom conversion.
  # Prevents atom exhaustion from arbitrary user input.
  @known_agents ~w(claude gemini codex goose opencode aider cline)

  defp safe_to_atom(agent_string) when is_binary(agent_string) do
    if agent_string in @known_agents do
      # Known agent — safe to convert (atoms exist at compile time via @known_agents)
      String.to_existing_atom(agent_string)
    else
      # Try existing atom (covers dynamically loaded providers)
      String.to_existing_atom(agent_string)
    end
  rescue
    ArgumentError ->
      Logger.warning("ACP adapter: unknown agent '#{agent_string}', falling back to :claude")
      @default_agent
  end

  defp pool_checkout(agent, opts) do
    if Code.ensure_loaded?(@pool_mod) and is_pid(Process.whereis(@pool_mod)) do
      apply(@pool_mod, :checkout, [agent, opts])
    else
      {:error, :pool_not_available}
    end
  catch
    :exit, reason -> {:error, {:pool_exit, reason}}
  end

  defp pool_checkin(session) do
    if Code.ensure_loaded?(@pool_mod) do
      apply(@pool_mod, :checkin, [session])
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp session_prompt(session, request, timeout) do
    prompt = extract_prompt(request)
    system_prompt = extract_system_prompt(request)

    send_opts =
      [timeout: timeout]
      |> maybe_add(:system_prompt, system_prompt)

    if Code.ensure_loaded?(@session_mod) do
      apply(@session_mod, :send_message, [session, prompt, send_opts])
    else
      {:error, :session_mod_not_available}
    end
  catch
    :exit, reason -> {:error, {:session_exit, reason}}
  end

  defp extract_prompt(request) do
    request.messages
    |> Enum.filter(fn msg -> msg.role == :user end)
    |> List.last()
    |> case do
      nil -> ""
      msg -> extract_text(msg.content)
    end
  end

  defp extract_system_prompt(request) do
    request.messages
    |> Enum.filter(fn msg -> msg.role in [:system, :developer] end)
    |> Enum.map(fn msg -> extract_text(msg.content) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(parts) when is_list(parts) do
    parts
    |> Enum.filter(fn
      %{type: :text} -> true
      %{type: "text"} -> true
      _ -> false
    end)
    |> Enum.map_join("\n", fn part ->
      Map.get(part, :text, Map.get(part, "text", ""))
    end)
  end

  defp extract_text(_), do: ""

  defp format_response(result, _request, agent) when is_map(result) do
    text = Map.get(result, "text") || Map.get(result, :text, "")
    stop_reason = Map.get(result, "stopReason") || Map.get(result, :stop_reason)
    usage = Map.get(result, "usage") || Map.get(result, :usage, %{})

    finish_reason =
      case stop_reason do
        "end_turn" -> :stop
        "max_tokens" -> :length
        "tool_use" -> :tool_calls
        _ -> :stop
      end

    %Response{
      text: text,
      finish_reason: finish_reason,
      content_parts: [],
      usage: normalize_usage(usage),
      warnings: [],
      raw: %{agent: to_string(agent), result: result}
    }
  end

  defp format_response(_result, _request, _agent) do
    %Response{text: "", finish_reason: :error, warnings: ["Unexpected result format"]}
  end

  defp normalize_usage(usage) when is_map(usage) do
    %{
      prompt_tokens: Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens, 0),
      completion_tokens: Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens, 0),
      total_tokens: Map.get(usage, "total_tokens") || Map.get(usage, :total_tokens, 0)
    }
  end

  defp normalize_usage(_), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
