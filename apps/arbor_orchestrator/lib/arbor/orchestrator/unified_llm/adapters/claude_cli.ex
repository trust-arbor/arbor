defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.ClaudeCli do
  @moduledoc """
  Provider adapter that calls the `claude` CLI binary via a persistent CliTransport.

  This adapter enables the orchestrator to use Claude without the full Arbor
  umbrella running — just needs the `claude` binary in PATH. Uses CliTransport
  GenServer for persistent NDJSON communication, enabling:

  - **Session continuity** — multi-turn conversations via transport session
  - **Lower latency** — no CLI startup overhead after first call
  - **Thinking blocks** — interactive mode produces extended thinking events

  Supports:
  - Model selection (opus, sonnet, haiku)
  - System prompts
  - Working directory (hands-like worktree execution)
  - Timeout control
  - Transparent transport restart on crash
  """

  @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.CliTransport
  alias Arbor.Orchestrator.UnifiedLLM.{Request, Response}

  require Logger

  @default_timeout 600_000
  @default_model "sonnet"

  # Agent name for lazy transport storage
  @transport_agent __MODULE__.TransportAgent

  @impl true
  def provider, do: "claude_cli"

  @impl true
  def complete(%Request{} = request, opts \\ []) do
    {system_messages, user_messages} = split_messages(request.messages)
    prompt = extract_prompt(user_messages)
    system_prompt = extract_system_prompt(system_messages)
    model = resolve_model(request.model)
    working_dir = Keyword.get(opts, :working_dir)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    stream_callback = Keyword.get(opts, :stream_callback)

    transport_opts =
      [timeout: timeout]
      |> maybe_add(:stream_callback, stream_callback)

    with {:ok, transport} <- ensure_transport(model, system_prompt, working_dir) do
      case CliTransport.complete(transport, prompt, system_prompt, transport_opts) do
        {:ok, %Response{}} = ok ->
          ok

        {:error, {:transport_exit, _reason}} = error ->
          # Transport crashed — clear cached pid so next call restarts
          clear_transport()
          error

        {:error, _} = error ->
          error
      end
    end
  end

  @doc "Returns true if the `claude` binary is available in PATH."
  def available? do
    System.find_executable("claude") != nil
  end

  # -- Transport Lifecycle --

  defp ensure_transport(model, system_prompt, working_dir) do
    case get_transport() do
      {:ok, pid} ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          # Stale pid — transport died without us noticing
          clear_transport()
          start_transport(model, system_prompt, working_dir)
        end

      :none ->
        start_transport(model, system_prompt, working_dir)
    end
  end

  defp start_transport(model, system_prompt, working_dir) do
    transport_opts =
      [model: model]
      |> maybe_add(:system_prompt, system_prompt)
      |> maybe_add(:cwd, working_dir)

    # Use GenServer.start (unlinked) — the adapter manages transport lifecycle
    # itself via Agent-based caching and Process.alive? checks. A linked start
    # would propagate transport crashes to the calling process.
    case GenServer.start(CliTransport, transport_opts) do
      {:ok, pid} ->
        store_transport(pid)
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("ClaudeCli: failed to start transport: #{inspect(reason)}")
        {:error, {:transport_start_failed, reason}}
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  # Simple Agent-based transport storage. The Agent is started lazily
  # on first access and stores a single transport pid.

  defp get_transport do
    ensure_agent_started()

    case Agent.get(@transport_agent, & &1) do
      nil -> :none
      pid -> {:ok, pid}
    end
  catch
    :exit, _ -> :none
  end

  defp store_transport(pid) do
    ensure_agent_started()
    Agent.update(@transport_agent, fn _old -> pid end)
  catch
    :exit, _ -> :ok
  end

  defp clear_transport do
    if Process.whereis(@transport_agent) do
      Agent.update(@transport_agent, fn _old -> nil end)
    end
  catch
    :exit, _ -> :ok
  end

  defp ensure_agent_started do
    unless Process.whereis(@transport_agent) do
      # Start unlinked so it outlives the caller
      Agent.start(fn -> nil end, name: @transport_agent)
    end
  end

  # -- Message Helpers (reused from Arborcli adapter pattern) --

  defp split_messages(messages) do
    Enum.split_with(messages, fn msg ->
      msg.role in [:system, :developer]
    end)
  end

  defp extract_prompt(user_messages) do
    user_messages
    |> Enum.filter(fn msg -> msg.role == :user end)
    |> List.last()
    |> case do
      nil -> ""
      msg -> extract_text(msg.content)
    end
  end

  defp extract_system_prompt(system_messages) do
    system_messages
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
      %{kind: :text} -> true
      _ -> false
    end)
    |> Enum.map(fn part ->
      Map.get(part, :text, Map.get(part, "text", ""))
    end)
    |> Enum.join("\n")
  end

  defp extract_text(_), do: ""

  defp resolve_model(nil), do: @default_model
  defp resolve_model("opus"), do: "opus"
  defp resolve_model("sonnet"), do: "sonnet"
  defp resolve_model("haiku"), do: "haiku"
  defp resolve_model("claude-opus-4-5" <> _), do: "opus"
  defp resolve_model("claude-sonnet-4" <> _), do: "sonnet"
  defp resolve_model("claude-haiku" <> _), do: "haiku"
  defp resolve_model(model) when is_binary(model), do: model
  defp resolve_model(model) when is_atom(model), do: Atom.to_string(model)
end
