defmodule Arbor.AI.LLM.Adapter.Acp do
  @moduledoc """
  Provider-adapter integration for ACP CLIs + discovery helpers.

  ## complete/2 — DEPRECATED

  The `complete/2` provider-adapter callback is the pre-runtime-axis
  execution path: `provider: "acp"` + `provider_options.agent` to pick
  the CLI. Phase 2c made `provider` name the model source (`:anthropic`,
  `:openai`, etc.) and `runtime: :acp` name the execution path. The
  new shape is `Arbor.AI.Runtime.Acp.execute/3`, dispatched through
  `Arbor.AI.Runtime.Dispatch.dispatch/2`, which reads the CLI from
  `request.provider` rather than from `provider_options`.

  Still functional for callers that hit `Arbor.LLM.Client.complete/3`
  directly with `provider: "acp"`. Future cleanup will migrate those
  callers and remove the callback; the deprecation attribute on
  `complete/2` flags the migration target.

  ## Discovery helpers — NOT deprecated

  `detected_agents/0`, `available_agents/0`, `install_hint/1`, and
  `runtime_contract/0` are general-purpose ACP utilities consumed by
  `mix arbor.doctor`, `Arbor.LLM.ProviderCatalog`, and other operator
  surfaces. They have no replacement in `Runtime.Acp` and stay here
  as the canonical discovery surface.

  See `.arbor/decisions/2026-06-04-slash-commands-for-runtime-config.md`
  for the Phase 2c context.

  ## Legacy input shape (still supported by `complete/2`)

      %Request{
        provider: "acp",
        model: "sonnet",
        provider_options: %{"agent" => "claude"}
      }

  ## New shape (use via `Dispatch.dispatch/2`)

      %Request{
        provider: "anthropic",
        runtime: :acp,
        model: "claude-opus-4-6"
      }
  """

  @behaviour Arbor.LLM.ProviderAdapter

  alias Arbor.LLM.Request

  alias Arbor.LLM.Response
  require Logger

  @default_agent :claude
  @default_timeout :infinity

  # Known ACP agent names for safe atom conversion.
  # Prevents atom exhaustion from arbitrary user input.
  @known_agents ~w(claude gemini codex goose opencode aider cline grok)

  # Runtime bridge targets (arbor_ai is Standalone)
  @pool_mod Arbor.AI.AcpPool
  @session_mod Arbor.AI.AcpSession

  @impl true
  def provider, do: "acp"

  @deprecated "Use Arbor.AI.Runtime.Acp via Arbor.AI.Runtime.Dispatch.dispatch/2. This path ships for backwards-compat with the pre-Phase-2c provider:\"acp\"+agent shape."
  @impl true
  def complete(%Request{} = request, opts \\ []) do
    fallback_opts =
      if is_nil(request.receive_timeout),
        do: opts,
        else: [receive_timeout: request.receive_timeout] ++ opts

    with {:ok, opts, _timeout} <- Arbor.AI.Timeout.start_deadline(fallback_opts, @default_timeout),
         {:ok, checkout_deadline_opts, timeout} <- Arbor.AI.Timeout.remaining(opts) do
      agent = resolve_agent(request)

      checkout_opts =
        checkout_deadline_opts
        |> Keyword.delete(:timeout)
        |> Keyword.put(:model, request.model)
        |> Keyword.put(:timeout, timeout)
        |> maybe_add(:workspace, extract_option(request, "workspace"))
        |> maybe_add(:agent_id, extract_option(request, "agent_id") || opts[:agent_id])
        |> maybe_add(:capabilities, extract_option(request, "capabilities"))

      case pool_checkout(agent, checkout_opts) do
        {:ok, session} ->
          prompt_result =
            with {:ok, prompt_opts, prompt_timeout} <- Arbor.AI.Timeout.remaining(opts) do
              session_prompt(session, request, prompt_opts, prompt_timeout)
            end

          case prompt_result do
            {:ok, result} ->
              pool_checkin(session, opts)

              with :ok <- Arbor.AI.Timeout.ensure_active(opts) do
                {:ok, format_response(result, request, agent)}
              end

            {:error, reason} ->
              # Always return session to pool, even on prompt failure
              pool_checkin(session, opts)

              Logger.warning(
                "ACP adapter prompt error (agent=#{agent}): #{Arbor.LLM.inspect_external_reason(reason)}"
              )

              {:error, Arbor.LLM.sanitize_external_reason(reason)}
          end

        {:error, reason} ->
          Logger.warning(
            "ACP adapter checkout error (agent=#{agent}): #{Arbor.LLM.inspect_external_reason(reason)}"
          )

          {:error, Arbor.LLM.sanitize_external_reason(reason)}
      end
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

    # Only include detected agents as cli_tools so RuntimeContract.check passes
    # when at least one agent is installed (empty list = :skipped = pass).
    found = detected_agents()

    cli_tools =
      if found == [] do
        # No agents found — include one required tool to trigger failure with hint
        [%{name: "claude", install_hint: "npm i -g @anthropic-ai/claude-code"}]
      else
        Enum.map(found, fn agent -> %{name: agent, install_hint: install_hint(agent)} end)
      end

    {:ok, contract} =
      RuntimeContract.new(
        provider: "acp",
        display_name: "ACP (CLI Agents)",
        type: :cli,
        cli_tools: cli_tools,
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

  @doc "Returns CLI agent binaries found in PATH."
  def detected_agents do
    Enum.filter(@known_agents, &System.find_executable/1)
  end

  @doc "Returns install hints for known ACP agents."
  def install_hint("claude"), do: "npm i -g @anthropic-ai/claude-code"
  def install_hint("gemini"), do: "npm i -g @google/gemini-cli"
  def install_hint("codex"), do: "npm i -g @openai/codex"
  def install_hint("goose"), do: "pip install goose-ai"
  def install_hint("aider"), do: "pip install aider-chat"
  def install_hint("grok"), do: "curl -fsSL https://x.ai/cli/install.sh | bash"
  def install_hint(_), do: "See agent documentation"

  # -- Private --

  defp resolve_agent(%Request{provider_options: opts}) when is_map(opts) do
    case Map.get(opts, "agent") || Map.get(opts, :agent) do
      nil -> @default_agent
      agent when is_binary(agent) -> safe_to_atom(agent)
      agent when is_atom(agent) -> agent
    end
  end

  defp resolve_agent(_), do: @default_agent

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
  rescue
    exception -> {:error, {:pool_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    :exit, reason -> {:error, {:pool_exit, Arbor.LLM.sanitize_external_reason(reason)}}
    kind, reason -> {:error, {:pool_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
  end

  defp pool_checkin(session, opts) do
    if Code.ensure_loaded?(@pool_mod) do
      case live_session_ready?(session) do
        true ->
          pool_call(session, :checkin, opts)

        false ->
          # A failed prompt may leave the provider session fenced in
          # :recovery_required. It is not reusable and must leave the pool,
          # even when this cleanup runs after the caller deadline.
          pool_call(session, :close_session, opts)
      end
    else
      :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp live_session_ready?(session) do
    if Code.ensure_loaded?(@session_mod) and function_exported?(@session_mod, :status, 1) do
      case apply(@session_mod, :status, [session]) do
        %{status: :ready} -> true
        _other -> false
      end
    else
      false
    end
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp pool_call(session, function, opts) do
    args = [session]
    supports_options? = function_exported?(@pool_mod, function, 2)

    case Arbor.AI.Timeout.remaining(opts) do
      {:ok, cleanup_opts, _remaining} when supports_options? ->
        apply(@pool_mod, function, args ++ [cleanup_opts])

      {:ok, _cleanup_opts, _remaining} ->
        apply(@pool_mod, function, args)

      {:error, _reason} ->
        Task.start(fn ->
          try do
            apply(@pool_mod, function, args)
          rescue
            _exception -> :ok
          catch
            _kind, _reason -> :ok
          end
        end)

        :ok
    end
  end

  defp session_prompt(session, request, opts, timeout) do
    prompt = extract_prompt(request)
    system_prompt = extract_system_prompt(request)

    send_opts =
      opts
      |> Keyword.take([:timeout, :deadline_ms])
      |> Keyword.put(:timeout, timeout)
      |> maybe_add(:system_prompt, system_prompt)

    if Code.ensure_loaded?(@session_mod) do
      apply(@session_mod, :send_message, [session, prompt, send_opts])
    else
      {:error, :session_mod_not_available}
    end
  rescue
    exception -> {:error, {:session_failed, Arbor.LLM.external_exception_message(exception)}}
  catch
    :exit, reason -> {:error, {:session_exit, Arbor.LLM.sanitize_external_reason(reason)}}
    kind, reason -> {:error, {:session_failure, kind, Arbor.LLM.sanitize_external_reason(reason)}}
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

  @doc false
  def normalize_usage(usage) when is_map(usage) do
    # Handle both snake_case (native ACP) and camelCase (Claude/Codex adapters)
    input =
      Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens) ||
        Map.get(usage, "inputTokens") || 0

    output =
      Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens) ||
        Map.get(usage, "outputTokens") || 0

    %{
      prompt_tokens: input,
      completion_tokens: output,
      total_tokens:
        Map.get(usage, "total_tokens") || Map.get(usage, :total_tokens, input + output)
    }
  end

  def normalize_usage(_), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  # Keys we extract from provider_options — both string and atom forms
  @provider_option_keys %{
    "workspace" => :workspace,
    "agent_id" => :agent_id
  }

  defp extract_option(%Request{provider_options: opts}, key) when is_map(opts) do
    atom_key = Map.get(@provider_option_keys, key, nil)
    Map.get(opts, key) || (atom_key && Map.get(opts, atom_key))
  end

  defp extract_option(_, _), do: nil

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
