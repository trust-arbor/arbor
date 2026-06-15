defmodule Arbor.Orchestrator.Handlers.LlmHandler do
  @moduledoc false

  @behaviour Arbor.Orchestrator.Handlers.Handler

  require Logger

  alias Arbor.Contracts.Pipeline.Response, as: PipelineResponse

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  alias Arbor.LLM.ArborActionsExecutor

  alias Arbor.LLM.Client

  alias Arbor.LLM.Dispatcher

  alias Arbor.LLM.FallbackLoop

  alias Arbor.LLM.Message

  alias Arbor.LLM.Request

  alias Arbor.LLM.StreamEvent

  alias Arbor.LLM.ToolLoop
  import Arbor.Orchestrator.Handlers.Helpers

  alias Arbor.Orchestrator.Session.Builders

  @prompt_sanitizer Arbor.Common.PromptSanitizer

  @impl true
  def execute(node, context, graph, opts) do
    # Provenance (taint-tracking-rebuild Phase 1): LLM output is :derived — it
    # may have incorporated untrusted content the model read, so it can never be
    # :trusted. The engine records this on the node's output keys. (Sanitization
    # bits are also wiped at :derived per council decision #6; that struct-level
    # nuance lands with Phase 4 — here we record the atom level.)
    case do_execute(node, context, graph, opts) do
      %Outcome{output_taint: nil} = outcome -> %{outcome | output_taint: :derived}
      other -> other
    end
  end

  defp do_execute(node, context, graph, opts) do
    goal = Map.get(graph.attrs, "goal", "")

    prompt =
      case Map.get(node.attrs, "prompt_context_key") do
        nil ->
          node.attrs
          |> Map.get("prompt", Map.get(node.attrs, "label", node.id))
          |> String.replace("$goal", to_string(goal))

        key ->
          Context.get(context, key, Map.get(node.attrs, "prompt", node.id))
      end

    # In decision mode, perspective nodes should evaluate the council question,
    # not their own node ID
    prompt = maybe_use_council_question(prompt, node.attrs, graph.attrs, context)

    base_updates = %{
      "last_stage" => node.id,
      "last_prompt" => prompt,
      "context.previous_outcome" => Context.get(context, "outcome"),
      "llm.model" => Map.get(node.attrs, "llm_model") || Map.get(node.attrs, "model"),
      "llm.provider" => Map.get(node.attrs, "llm_provider") || Map.get(node.attrs, "handler"),
      "llm.reasoning_effort" => Map.get(node.attrs, "reasoning_effort"),
      "score" => parse_score(Map.get(node.attrs, "score"))
    }

    simulate_attr = Map.get(node.attrs, "simulate")

    case simulate_attr do
      "fail" ->
        %Outcome{
          status: :fail,
          failure_reason: "simulated failure",
          context_updates: Map.put(base_updates, "last_response", "[Simulated] failure")
        }

      "retry" ->
        %Outcome{
          status: :retry,
          failure_reason: "simulated retry",
          context_updates: Map.put(base_updates, "last_response", "[Simulated] retry")
        }

      "fail_once" ->
        key = "internal.simulate.fail_once.#{node.id}"
        attempts = Context.get(context, key, 0)

        if attempts == 0 do
          %Outcome{
            status: :fail,
            failure_reason: "simulated fail once",
            context_updates:
              base_updates
              |> Map.put("last_response", "[Simulated] fail once")
              |> Map.put(key, 1)
          }
        else
          response = "[Simulated] Response for stage: #{node.id}"
          _ = write_stage_artifacts(opts, node.id, prompt, response)

          %Outcome{
            status: :success,
            notes: "Stage completed: #{node.id}",
            context_updates: Map.put(base_updates, "last_response", response)
          }
        end

      "raise_retryable" ->
        raise "network timeout"

      "raise_terminal" ->
        raise "401 unauthorized"

      simulate when simulate in [nil, "true", true] ->
        Logger.warning("[LlmHandler] #{node.id}: SIMULATED (simulate=#{inspect(simulate_attr)})")

        # Simulation mode — no real LLM call
        response = "[Simulated] Response for stage: #{node.id}"
        _ = write_stage_artifacts(opts, node.id, prompt, response)

        %Outcome{
          status: :success,
          notes: "Stage completed: #{node.id}",
          context_updates: Map.put(base_updates, "last_response", response)
        }

      "false" ->
        # Real LLM call
        call_llm_and_respond(prompt, node, context, graph, base_updates, opts)
    end
  end

  @impl true
  def idempotency, do: :idempotent_with_key

  defp call_llm_and_respond(prompt, node, context, graph, base_updates, opts) do
    # Egress gate (2026-06-14 URI-addressing-vs-classification decision). The
    # compute-node LLM path has no per-operation capability, so we check egress
    # standing directly via Arbor.Security.authorize_egress/3 before dispatching.
    # Runtime indirection — arbor_orchestrator does not hard-dep arbor_security.
    # Inert unless egress enforcement is switched on; emits observability while
    # dark. A gate CRASH fails open (never let the gate halt LLM on a bug).
    case egress_halt_outcome(context, base_updates) do
      %Outcome{} = halt -> halt
      _ -> call_llm_and_respond_allowed(prompt, node, context, graph, base_updates, opts)
    end
  end

  defp call_llm_and_respond_allowed(prompt, node, context, graph, base_updates, opts) do
    agent_id = Context.get(context, "session.agent_id", "?")
    prompt_len = if is_binary(prompt), do: String.length(prompt), else: 0
    msgs_count = context |> Context.get("session.messages", []) |> length()
    provider = Context.get(context, "session.llm_provider")
    model = Context.get(context, "session.llm_model")
    use_tools = Map.get(node.attrs, "use_tools") in ["true", true]

    Logger.info(
      "[LlmHandler] #{node.id} for #{agent_id}: " <>
        "prompt=#{prompt_len} chars, messages=#{msgs_count}, " <>
        "provider=#{provider}, model=#{model}"
    )

    emit_llm_signal(:llm_call_started, %{
      agent_id: agent_id,
      node_id: node.id,
      provider: provider,
      model: model,
      prompt_length: prompt_len,
      message_count: msgs_count,
      use_tools: use_tools
    })

    # Clear any stale routing decision from process dict
    Process.delete(:__routing_decision__)
    start_time = System.monotonic_time(:millisecond)

    # Telemetry span around the actual LLM call: emits
    # [:arbor, :llm, :call, :start | :stop | :exception] with :duration. Stop metadata
    # carries provider/model and :result (:ok | :error). Attach a handler via
    # Arbor.Signals.Telemetry to profile LLM latency by provider/model.
    span_meta = %{
      agent_id: agent_id,
      node_id: node.id,
      provider: provider,
      model: model,
      use_tools: use_tools
    }

    llm_result =
      :telemetry.span([:arbor, :llm, :call], span_meta, fn ->
        result = call_llm(prompt, node, context, graph, opts)
        outcome = if match?({:ok, _}, result), do: :ok, else: :error
        {result, Map.put(span_meta, :result, outcome)}
      end)

    # Opt-in auto-retry when a reasoning model exhausts max_tokens mid-CoT
    # (text == "" + reasoning_content non-empty + finish_reason :length).
    # Default off. Per-node attrs: `auto_retry_on_reasoning_cutoff="true"`
    # and `auto_retry_max_tokens_multiplier="N"` (default 2). Retries ONCE;
    # if the retry also cuts off, both warnings are appended and we give up.
    llm_result = maybe_retry_on_reasoning_cutoff(llm_result, prompt, node, context, graph, opts)

    case llm_result do
      {:ok, raw_response} ->
        response = PipelineResponse.normalize(raw_response)
        response_text = response.content

        if response_text == "" do
          # Surface reasoning_content too: for reasoning-tuned models (gemma
          # e4b, qwen-mtp, deepseek-r1, etc.) an empty text + non-empty
          # reasoning means max_tokens was exhausted mid-CoT before the
          # final answer could be produced. The diagnostic field tells
          # operators "bump max_tokens" rather than "model is broken."
          reasoning_size =
            case Map.get(raw_response, :reasoning_content) do
              nil -> :no_reasoning_key
              "" -> :empty
              s when is_binary(s) -> {:chars, byte_size(s)}
              other -> {:unexpected, inspect(other, limit: 50)}
            end

          Logger.warning(
            "[LlmHandler] Empty response after normalize. " <>
              "raw_type=#{inspect(Map.get(raw_response, :__struct__, :plain_map), limit: 50) |> String.slice(0..80)} " <>
              "raw_content=#{inspect(Map.get(raw_response, :content, :no_content_key), limit: 200)} " <>
              "raw_text=#{inspect(Map.get(raw_response, :text, :no_text_key), limit: 200)} " <>
              "reasoning=#{inspect(reasoning_size)} " <>
              "tool_rounds=#{inspect(response.tool_rounds)}"
          )

          # Phase 1 diagnostic: when the warning above fires, debug-level
          # consumers (operators chasing a new model variant) can see the
          # structural shape of the underlying ReqLLM.Response.
          # Field names + value sizes/types, no literal text content —
          # enough to spot "content went into provider_meta.reasoning_text"
          # without flooding logs or leaking prompt/output content.
          log_empty_response_shape(raw_response)
        end

        elapsed = System.monotonic_time(:millisecond) - start_time
        resp_len = String.length(response_text)

        Logger.info(
          "[LlmHandler] #{node.id} for #{agent_id}: " <>
            "OK in #{elapsed}ms, response=#{resp_len} chars"
        )

        emit_llm_signal(:llm_call_completed, %{
          agent_id: agent_id,
          node_id: node.id,
          provider: provider,
          model: model,
          duration_ms: elapsed,
          response_length: resp_len,
          response_preview:
            if(is_binary(response_text), do: String.slice(response_text, 0..200), else: nil),
          use_tools: use_tools
        })

        _ = write_stage_artifacts(opts, node.id, prompt, response_text)

        # Merge duration and provider/model into usage for telemetry
        usage_with_meta =
          (response.usage || %{})
          |> Map.put("duration_ms", elapsed)
          |> Map.put("provider", provider)
          |> Map.put("model", model)

        updates =
          base_updates
          |> Map.put("last_response", response_text)
          |> Map.put("session.usage", usage_with_meta)
          |> Map.put("session.tool_round_count", response.tool_rounds)
          |> maybe_put_perspective_key(node.attrs, response_text)
          |> maybe_put_routing_decision()
          |> maybe_put_discovered_tools()

        %Outcome{
          status: :success,
          notes: response_text,
          context_updates: updates
        }

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        error_info = classify_error(reason)

        Logger.warning(
          "[LlmHandler] #{node.id} for #{agent_id}: " <>
            "FAILED in #{elapsed}ms, error_type=#{error_info.type} error=#{error_info.message}"
        )

        emit_llm_signal(:llm_call_failed, %{
          agent_id: agent_id,
          node_id: node.id,
          provider: provider,
          model: model,
          duration_ms: elapsed,
          error_type: error_info.type,
          error_message: error_info.message,
          http_status: error_info.status,
          error_code: error_info.code,
          retryable: error_info.retryable,
          retry_after_ms: error_info.retry_after_ms,
          # Backward compat
          error: error_info.message,
          use_tools: use_tools
        })

        %Outcome{
          status: :fail,
          failure_reason: "LLM call failed: #{error_info.message}",
          context_updates: Map.put(base_updates, "last_response", nil)
        }
    end
  end

  # ── Egress gate (2026-06-14) — compute-node LLM path ──────────────────────
  #
  # Returns a halt %Outcome{} when egress is blocked/requires-approval, else nil
  # (proceed). All cross-library calls are guarded runtime indirection (the
  # orchestrator does not hard-dep arbor_security/arbor_ai); a crash fails open.

  @taint_severity %{trusted: 0, derived: 1, untrusted: 2, hostile: 3}

  defp egress_halt_outcome(context, base_updates) do
    security = Arbor.Security

    if Code.ensure_loaded?(security) and function_exported?(security, :authorize_egress, 3) do
      agent_id = Context.get(context, "session.agent_id", "system")
      tier = resolve_egress_tier(Context.get(context, "session.llm_provider"))
      taint = egress_taint_level(context)

      case apply(security, :authorize_egress, [agent_id, tier, [egress_taint: taint]]) do
        :allow ->
          nil

        {:requires_approval, _} ->
          %Outcome{
            status: :fail,
            failure_reason: "LLM egress requires approval (#{tier}); agent lacks egress standing",
            context_updates: base_updates
          }

        {:error, {:egress_blocked, t, reason}} ->
          %Outcome{
            status: :fail,
            failure_reason: "LLM egress blocked (#{t}/#{reason})",
            context_updates: base_updates
          }
      end
    end
  rescue
    e ->
      Logger.warning("[LlmHandler] egress gate error (failing open): #{Exception.message(e)}")
      nil
  end

  # Resolve the egress tier for the provider via BackendTrust (provider -> tier).
  # Falls back to :external_provider (the gated tier) if AI is unavailable.
  defp resolve_egress_tier(provider) do
    backend_trust = Arbor.AI.BackendTrust

    if Code.ensure_loaded?(backend_trust) and
         function_exported?(backend_trust, :egress_tier_for, 2) do
      apply(backend_trust, :egress_tier_for, [provider_atom(provider), nil])
    else
      :external_provider
    end
  end

  defp provider_atom(provider) when is_atom(provider) and not is_nil(provider), do: provider

  defp provider_atom(provider) when is_binary(provider) do
    case Arbor.Common.SafeAtom.to_existing(provider) do
      {:ok, atom} -> atom
      _ -> nil
    end
  end

  defp provider_atom(_), do: nil

  # Conservative egress taint: the MOST severe level across all context taint —
  # the prompt may incorporate any context data, so if anything is untrusted/
  # hostile, treat the egress as carrying it. Returns nil when no taint present.
  defp egress_taint_level(context) do
    context
    |> Map.get(:taint, %{})
    |> Map.values()
    |> Enum.map(fn t -> Map.get(t, :level, :derived) end)
    |> Enum.max_by(fn level -> Map.get(@taint_severity, level, 1) end, fn -> nil end)
  end

  defp call_llm(prompt, node, context, graph, opts) do
    client = Keyword.get(opts, :llm_client) || Client.default_client()
    nonce = @prompt_sanitizer.generate_nonce()

    {system_content, user_content} = build_llm_messages(prompt, node, context, graph, nonce)

    case build_llm_request(node, context, system_content, user_content) do
      {:ok, request} ->
        call_opts = build_call_opts(node, opts)
        on_stream = Keyword.get(opts, :on_stream)

        call_opts =
          if on_stream do
            Keyword.put(call_opts, :stream_callback, on_stream)
          else
            call_opts
          end

        use_tools = Map.get(node.attrs, "use_tools") in ["true", true]

        if use_tools do
          call_llm_with_tools(client, request, node, context, on_stream, opts)
        else
          call_llm_direct(client, request, call_opts, context, on_stream)
        end

      {:error, _} = error ->
        error
    end
  end

  defp build_llm_messages(prompt, node, context, graph, nonce) do
    previous_outcome =
      case Map.get(node.attrs, "context.previous_outcome") do
        nil -> ""
        outcome -> "\n\nPrevious stage outcome: #{@prompt_sanitizer.wrap(outcome, nonce)}"
      end

    goal = Map.get(graph.attrs, "goal", "")

    system_content =
      case Map.get(node.attrs, "system_prompt_context_key") do
        nil ->
          case Map.get(node.attrs, "system_prompt") do
            nil ->
              "You are a coding agent working on the following goal: #{@prompt_sanitizer.wrap(goal, nonce)}"

            sys ->
              sys
          end

        key ->
          Context.get(context, key, "You are a coding agent.")
      end

    system_content = @prompt_sanitizer.preamble(nonce) <> "\n\n" <> system_content
    system_content = maybe_prepend_vote_format(system_content, node.attrs, graph.attrs)
    user_content = prompt <> previous_outcome

    {system_content, user_content}
  end

  defp build_llm_request(node, context, system_content, user_content) do
    messages =
      case Map.get(node.attrs, "messages_context_key") do
        nil ->
          [
            Message.new(:system, system_content),
            Message.new(:user, user_content)
          ]

        key ->
          case Context.get(context, key) do
            msgs when is_list(msgs) and msgs != [] ->
              # Prepend system message, use context messages as conversation history
              [Message.new(:system, system_content) | to_messages(msgs)]

            _ ->
              [
                Message.new(:system, system_content),
                Message.new(:user, user_content)
              ]
          end
      end

    # Provider/model: node attrs take priority, fall back to context
    provider =
      Map.get(node.attrs, "llm_provider") ||
        Map.get(node.attrs, "handler") ||
        Context.get(context, "session.llm_provider")

    model =
      Map.get(node.attrs, "llm_model") ||
        Map.get(node.attrs, "model") ||
        Context.get(context, "session.llm_model")

    # Runtime axis (Phase 2d): per-turn node attr > Session config > :arbor.
    # Maps directly to request.runtime, which the registered
    # Arbor.AI.Runtime.<atom> adapter then dispatches against.
    runtime =
      case Map.get(node.attrs, "llm_runtime") do
        nil -> Context.get(context, "session.llm_runtime", :arbor)
        atom when is_atom(atom) -> atom
        str when is_binary(str) -> safe_runtime_atom(str)
      end

    # Sensitivity routing: reroute if the current provider can't handle the data
    case maybe_route_by_sensitivity(provider, model, context) do
      {:error, _} = error ->
        error

      {routed_provider, routed_model} ->
        {:ok,
         %Request{
           provider: routed_provider,
           model: routed_model,
           runtime: runtime,
           messages: messages,
           max_tokens: parse_int(Map.get(node.attrs, "max_tokens"), 4096),
           temperature: parse_float(Map.get(node.attrs, "temperature"), 0.7),
           # Forwards to req_llm as :receive_timeout (HTTP-layer cutoff).
           # req_llm defaults to 30s for openai-compatible providers, which
           # is too short for slower local models or long tool-use turns.
           # `timeout` node attr also sets Arbor.LLM.Client's outer timeout
           # (see build_call_opts/2), so both layers stay aligned.
           receive_timeout: parse_int(Map.get(node.attrs, "timeout"), nil),
           provider_options:
             node.attrs
             |> build_provider_options(Context.get(context, "session.acp_agent"))
             |> maybe_put_workspace(Context.get(context, "session.acp_workspace"))
         }}
    end
  end

  # ACP agents (e.g. grok) require a non-null cwd for session/new even when the call
  # only synthesizes text. Callers set `session.acp_workspace` (a `{:directory, path}`
  # or `{:worktree, ...}` term) so sub-pipelines can supply a workspace via context.
  defp maybe_put_workspace(po, nil), do: po
  defp maybe_put_workspace(po, workspace), do: Map.put(po, "workspace", workspace)

  # Flat `agent` attr (or `session.acp_agent` context fallback, mirroring provider/model)
  # + JSON `provider_options` string → map; `agent` picks the ACP CLI (else provider="acp"
  # defaults to :claude). Context fallback lets sub-pipelines parameterize the agent.
  #
  # ACP adapter constraints (2026-06-06): pipelines that route through
  # the `:acp` runtime can carry per-node permission / tool restrictions
  # for the ExMCP Claude (ClaudeSDK) adapter via three node attrs:
  #
  #   acp_permission_mode="deny"
  #   acp_allowed_tools="WebSearch,WebFetch"
  #   acp_disallowed_tools="Write,Edit"
  #
  # These get packed into `provider_options["acp_adapter_opts"]` as a
  # keyword list, which `Runtime.Acp.build_checkout_opts/2` forwards to
  # `AcpSession.Config.merge_opts/2` for merging with the
  # provider-default `adapter_opts`. Per-call (per-node) settings win.
  defp build_provider_options(attrs, agent_override) do
    base =
      case Map.get(attrs, "provider_options") do
        m when is_map(m) ->
          m

        s when is_binary(s) ->
          case Jason.decode(s) do
            {:ok, m} when is_map(m) -> m
            _ -> %{}
          end

        _ ->
          %{}
      end

    base = put_acp_adapter_opts(base, attrs)

    case Map.get(attrs, "agent") || agent_override do
      nil -> base
      agent -> Map.put(base, "agent", agent)
    end
  end

  defp put_acp_adapter_opts(provider_options, attrs) do
    adapter_opts =
      []
      |> append_permission_mode(attrs)
      |> append_tool_list(attrs, "acp_allowed_tools", :allowed_tools)
      |> append_tool_list(attrs, "acp_disallowed_tools", :disallowed_tools)

    case adapter_opts do
      [] -> provider_options
      ao -> Map.put(provider_options, "acp_adapter_opts", ao)
    end
  end

  defp append_permission_mode(kw, attrs) do
    case Map.get(attrs, "acp_permission_mode") do
      nil ->
        kw

      mode when is_binary(mode) ->
        atom = safe_permission_atom(mode)
        if atom, do: Keyword.put(kw, :permission_mode, atom), else: kw

      atom when is_atom(atom) ->
        Keyword.put(kw, :permission_mode, atom)
    end
  end

  defp append_tool_list(kw, attrs, attr_key, opt_key) do
    case Map.get(attrs, attr_key) do
      nil ->
        kw

      str when is_binary(str) ->
        tools =
          str
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        case tools do
          [] -> kw
          list -> Keyword.put(kw, opt_key, list)
        end

      list when is_list(list) ->
        Keyword.put(kw, opt_key, list)
    end
  end

  # Whitelist of permission-mode atoms — DOT attrs come from operator-
  # authored files but still go through atom encoding; pin to the
  # known set to avoid unbounded atom growth and surprise modes.
  # The recognized values mirror ExMCP.ACP.Adapters.ClaudeSDK's
  # `encode_permission_mode/1` mapping to Claude CLI's `--permission-mode`
  # values. See code.claude.com/docs/en/permissions for semantics.
  defp safe_permission_atom(str) do
    case str do
      "nil" -> nil
      "bypass" -> :bypass
      "default" -> :default
      "accept_edits" -> :accept_edits
      "plan" -> :plan
      "auto" -> :auto
      "dont_ask" -> :dont_ask
      "bypass_permissions" -> :bypass_permissions
      _ -> nil
    end
  end

  defp to_messages(msgs) do
    msgs
    |> Enum.reject(&empty_assistant?/1)
    |> Enum.map(fn
      %Message{} = m ->
        m

      %{"role" => role, "content" => content} ->
        Message.new(String.to_existing_atom(role), content)

      %{role: role, content: content} ->
        Message.new(role, content)
    end)
  end

  defp empty_assistant?(%{"role" => "assistant", "content" => c}) when c in [nil, ""], do: true
  defp empty_assistant?(%{role: :assistant, content: c}) when c in [nil, ""], do: true
  defp empty_assistant?(_), do: false

  defp build_call_opts(node, opts) do
    case parse_int(Map.get(node.attrs, "timeout"), nil) do
      nil -> opts
      timeout_ms -> Keyword.put(opts, :timeout, timeout_ms)
    end
  end

  defp call_llm_with_tools(client, request, node, context, on_stream, opts) do
    workdir = Map.get(node.attrs, "workdir") || Keyword.get(opts, :workdir, ".")
    max_turns = parse_int(Map.get(node.attrs, "max_turns"), 50)

    {tool_defs, executor} = resolve_tools(node, context, opts)

    agent_id =
      Map.get(node.attrs, "agent_id") ||
        Context.get(context, "session.agent_id", "system")

    # Annotate ask-mode tools with "(requires approval)" in description
    tool_defs = annotate_ask_mode_tools(tool_defs, agent_id)

    # Extract signer from context — allows cryptographic identity verification
    # for every tool call executed within the pipeline
    signer =
      Keyword.get(opts, :signer) ||
        Context.get(context, "session.signer")

    tool_loop_opts =
      [
        workdir: workdir,
        max_turns: max_turns,
        tools: tool_defs,
        tool_executor: executor,
        agent_id: agent_id,
        signer: signer,
        on_tool_call: build_tool_callback(opts, node.id)
      ]
      |> maybe_add_stream_callback(on_stream)

    # Phase 4+ (B4): wrap ToolLoop in a fallback loop so per-agent
    # fallback chains apply to tool turns too. ToolLoop itself stays in
    # arbor_llm and uses Client.complete internally — moving it would
    # require behaviour-injection through ToolLoop too. For now we accept
    # that tool-loop fallback only supports provider/model swaps; :runtime
    # entries are skipped with a warning (they'd require dispatching the
    # whole loop through a different runtime, which is incoherent for a
    # multi-turn conversation).
    chain = Context.get(context, "session.llm_fallback_chain", [])
    do_call = fn req -> tool_loop_attempt(client, req, tool_loop_opts) end
    call_with_tool_loop_fallback(do_call, request, chain)
  end

  defp tool_loop_attempt(client, request, tool_loop_opts) do
    case ToolLoop.run(client, request, tool_loop_opts) do
      {:ok, %PipelineResponse{} = result} ->
        if result.discovered_tools != nil and result.discovered_tools != [] do
          Process.put(:__discovered_tool_names__, result.discovered_tools)
        end

        {:ok, result}

      {:error, {:max_turns_reached, turns, _}} ->
        {:error, "Tool loop hit #{turns} turn limit without completing"}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  # Exposed (@doc false) so tests can pin the tool-loop fallback shape
  # without spinning up a real Client + ToolLoop. Production callers
  # should not depend on this — it's adapter-internal.
  def call_with_tool_loop_fallback(do_call, request, chain) do
    FallbackLoop.run(request, chain,
      do_call: do_call,
      apply_override: &apply_tool_loop_override_with_warning/2,
      on_fallback: &log_tool_loop_fallback/3
    )
  end

  defp apply_tool_loop_override_with_warning(request, override) do
    override = warn_if_runtime_override(override)
    apply_tool_loop_override(request, override)
  end

  defp log_tool_loop_fallback(_initial, override, _last_error) do
    Logger.info("[LlmHandler] tool-loop fallback: applying override #{inspect(override)}")
  end

  defp warn_if_runtime_override(%{runtime: runtime} = override) do
    Logger.warning(
      "[LlmHandler] tool-loop fallback entry has :runtime (#{inspect(runtime)}) but " <>
        "tool loops go through Client.complete; runtime override has no effect here. " <>
        "Drop it from the entry to silence this warning."
    )

    Map.delete(override, :runtime)
  end

  defp warn_if_runtime_override(override), do: override

  defp apply_tool_loop_override(%Request{} = request, override) do
    has_provider = Map.has_key?(override, :provider)
    has_model = Map.has_key?(override, :model)

    if has_provider or has_model do
      updated =
        request
        |> maybe_put_field(:provider, Map.get(override, :provider))
        |> maybe_put_field(:model, Map.get(override, :model))

      {:ok, updated}
    else
      :no_change
    end
  end

  defp maybe_put_field(request, _field, nil), do: request

  defp maybe_put_field(request, :provider, provider) when is_atom(provider) do
    %{request | provider: Atom.to_string(provider)}
  end

  defp maybe_put_field(request, :provider, provider) when is_binary(provider) do
    %{request | provider: provider}
  end

  defp maybe_put_field(request, :model, model) when is_binary(model) do
    %{request | model: model}
  end

  defp maybe_put_field(request, _field, _value), do: request

  # Phase 4+ (B2): route through Dispatcher.dispatch so the runtime
  # axis selection chain + fallback chain from c12bf750 actually fire
  # for heartbeat + turn LLM calls. Direct Client.complete used to skip
  # all of that (Client.resolve_adapter only reads request.provider, not
  # request.runtime, and there's no selection/fallback layer in Client).
  #
  # Phase 4+ (B3): policy.fallback_chain comes from the persisted
  # `session.llm_fallback_chain` context key (seeded by ContextBuilder
  # from state.config["llm_fallback_chain"], which Lifecycle resolves
  # from the agent's profile + model_config).
  defp call_llm_direct(client, request, call_opts, context, nil) do
    dispatch_opts =
      call_opts
      |> Keyword.put(:client, client)
      |> Keyword.put(:policy, build_dispatch_policy(context, request))

    run_id = Keyword.get(call_opts, :run_id)

    # Long reasoning calls + HITL waits can block longer than the
    # RecoveryCoordinator's stale threshold. Refresh the heartbeat
    # while dispatch blocks. No-op when run_id isn't set (out-of-engine
    # call sites like tests). See HeartbeatRefresher moduledoc.
    Arbor.Orchestrator.HeartbeatRefresher.with_heartbeat_refresh(run_id, fn ->
      Dispatcher.dispatch(request, dispatch_opts)
    end)
  end

  defp call_llm_direct(client, request, call_opts, context, on_stream) do
    # Bridge the legacy single-callback on_stream (which receives raw
    # %StreamEvent{}) to Runtime.callbacks shape. Each typed callback
    # synthesizes a StreamEvent the legacy consumer expects. Events that
    # Runtime.Arbor doesn't dispatch (:step_finish, :tool_result) are
    # not forwarded — none of our current on_stream consumers depend on
    # those, and the conversion can extend if a real need surfaces.
    callbacks = stream_event_callbacks(on_stream)

    dispatch_opts =
      call_opts
      |> Keyword.put(:client, client)
      |> Keyword.put(:callbacks, callbacks)
      |> Keyword.put(:policy, build_dispatch_policy(context, request))

    run_id = Keyword.get(call_opts, :run_id)

    Arbor.Orchestrator.HeartbeatRefresher.with_heartbeat_refresh(run_id, fn ->
      Dispatcher.dispatch(request, dispatch_opts)
    end)
  end

  # Assemble the Selector policy from session context. Currently
  # carries fallback_chain only; runtime/provider/model overrides flow
  # via the Request struct itself (Selector reads them as pins). Add
  # more fields here as additional policy controls land.
  defp build_dispatch_policy(context, request) do
    policy = %{fallback_chain: Context.get(context, "session.llm_fallback_chain", [])}

    # Forward the request's runtime as a per-turn Selector override.
    # Without this, `Selector.choose/2` falls back to its default of
    # `:arbor`, which means a node attr like `llm_runtime="acp"` ends
    # up on the Request struct but never reaches the Selector chain —
    # the Request gets rewritten to whatever runtime the default picks
    # before Runtime dispatch.
    #
    # Source of truth is `request.runtime` (already resolved in
    # `build_llm_request/4` from node attr → session.llm_runtime →
    # default). We forward it here so Selector + rewrite_request agree
    # on which runtime to use.
    runtime =
      case request do
        %{runtime: r} when is_atom(r) and not is_nil(r) and r != :arbor -> r
        _ -> nil
      end

    if runtime, do: Map.put(policy, :runtime, runtime), else: policy
  end

  defp stream_event_callbacks(on_stream) when is_function(on_stream, 1) do
    %{
      on_text_delta: fn chunk ->
        on_stream.(%StreamEvent{type: :delta, data: %{"text" => chunk}})
      end,
      on_thinking_delta: fn chunk ->
        on_stream.(%StreamEvent{type: :delta, data: %{"thinking" => chunk}})
      end,
      on_tool_call: fn data ->
        on_stream.(%StreamEvent{type: :tool_call, data: data})
      end,
      on_usage: fn usage ->
        on_stream.(%StreamEvent{type: :finish, data: %{usage: usage}})
      end
    }
  end

  # Resolve which tools and executor to use based on node attributes.
  # Priority: node attrs "tools" > session.tools from context > all actions default.
  # The `tool_executor` opt allows test injection.
  defp resolve_tools(node, context, opts) do
    executor = Keyword.get(opts, :tool_executor, ArborActionsExecutor)

    case Map.get(node.attrs, "tools") do
      nil ->
        case Context.get(context, "session.tools") do
          session_tools when is_list(session_tools) and session_tools != [] ->
            {resolve_tool_list(session_tools), executor}

          _ ->
            {ArborActionsExecutor.definitions(), executor}
        end

      tools_str when is_binary(tools_str) ->
        action_names = String.split(tools_str, ",", trim: true)
        {ArborActionsExecutor.definitions(action_names), executor}
    end
  end

  # Convert a list of tool items to OpenAI-format definitions.
  # Accepts action name strings, module atoms, or already-formatted maps.
  defp resolve_tool_list(tools) do
    {names, maps} =
      Enum.split_with(tools, fn
        item when is_binary(item) -> true
        item when is_atom(item) -> true
        _ -> false
      end)

    name_defs =
      if names != [] do
        string_names =
          Enum.map(names, fn
            mod when is_atom(mod) ->
              if function_exported?(mod, :name, 0), do: mod.name(), else: inspect(mod)

            name ->
              name
          end)

        ArborActionsExecutor.definitions(string_names)
      else
        []
      end

    name_defs ++ maps
  end

  # Annotate tool definitions for tools that require approval (`:ask` mode in trust profile).
  # Appends "(requires approval)" to the description so the LLM knows to explain
  # why it needs the tool before calling it.
  defp annotate_ask_mode_tools(tool_defs, agent_id) do
    alias Arbor.Orchestrator.Session.ToolDisclosure

    ask_tools = ToolDisclosure.ask_mode_tools(agent_id)

    if MapSet.size(ask_tools) == 0 do
      tool_defs
    else
      Enum.map(tool_defs, fn tool_def ->
        name = get_in(tool_def, ["function", "name"])

        if name && MapSet.member?(ask_tools, name) do
          update_in(tool_def, ["function", "description"], fn desc ->
            desc = desc || ""

            if String.contains?(desc, "(requires approval)") do
              desc
            else
              desc <> " (requires approval)"
            end
          end)
        else
          tool_def
        end
      end)
    end
  rescue
    _ -> tool_defs
  end

  defp maybe_add_stream_callback(opts, nil), do: opts

  defp maybe_add_stream_callback(opts, callback) do
    Keyword.put(opts, :stream_callback, callback)
  end

  defp build_tool_callback(opts, node_id) do
    case Keyword.get(opts, :logs_root) do
      nil ->
        nil

      logs_root ->
        fn name, args, result ->
          tool_log_dir = Path.join([logs_root, node_id, "tool_calls"])
          File.mkdir_p!(tool_log_dir)
          timestamp = System.system_time(:millisecond)
          status = if match?({:ok, _}, result), do: "ok", else: "error"

          entry = %{
            "tool" => name,
            "args" => args,
            "status" => status,
            "timestamp" => timestamp
          }

          File.write!(
            Path.join(tool_log_dir, "#{timestamp}_#{name}.json"),
            Jason.encode!(entry, pretty: true)
          )
        end
    end
  end

  # Consult the sensitivity router if data sensitivity is known.
  # Uses runtime bridge (Code.ensure_loaded? + apply) because
  # arbor_orchestrator and arbor_ai are both Standalone — no compile dep.
  defp maybe_route_by_sensitivity(provider, model, context) do
    sensitivity = Context.get(context, "__data_sensitivity__")

    if sensitivity && sensitivity != :public && sensitivity_router_available?() do
      agent_id = Context.get(context, "session.agent_id")

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      decision =
        apply(Arbor.AI.SensitivityRouter, :decide, [
          safe_to_atom(provider),
          model || "",
          sensitivity,
          [agent_id: agent_id]
        ])

      case decision do
        %{action: :proceed} ->
          maybe_record_routing_telemetry(agent_id, :classified)
          {provider, model}

        %{action: :rerouted, alternative: {p, m}} = d ->
          maybe_record_routing_telemetry(agent_id, :rerouted)

          # Store routing decision in process dict for context_updates propagation.
          # call_llm_and_respond merges this into the Outcome's context_updates.
          Process.put(:__routing_decision__, %{
            action: :rerouted,
            original: d.original,
            alternative: d.alternative,
            sensitivity: d.sensitivity,
            mode: d.mode,
            reason: d.reason
          })

          {to_string(p), m}

        %{action: :blocked, reason: reason} ->
          maybe_record_routing_telemetry(agent_id, :blocked)
          {:error, {:sensitivity_blocked, reason}}
      end
    else
      {provider, model}
    end
  rescue
    _ -> {provider, model}
  catch
    :exit, _ -> {provider, model}
  end

  defp sensitivity_router_available? do
    Code.ensure_loaded?(Arbor.AI.SensitivityRouter) and
      function_exported?(Arbor.AI.SensitivityRouter, :decide, 4)
  end

  defp safe_to_atom(value) when is_atom(value), do: value

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :unknown
  end

  defp safe_to_atom(_), do: :unknown

  # Restrict runtime atom conversion to the known set. Unknown strings
  # fall back to :arbor (the safe default) rather than failing the turn
  # — a typo in `llm_runtime="arbour"` shouldn't break the LLM call.
  defp safe_runtime_atom("arbor"), do: :arbor
  defp safe_runtime_atom("acp"), do: :acp
  defp safe_runtime_atom(_), do: :arbor

  defp parse_float(nil, default), do: default
  defp parse_float(value, _default) when is_float(value), do: value
  defp parse_float(value, _default) when is_integer(value), do: value / 1

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp parse_float(_, default), do: default

  @vote_format_prefix """
  You MUST respond with a JSON object in this exact format:
  {"vote": "approve" or "reject" or "abstain", "reasoning": "your detailed reasoning", "confidence": 0.0-1.0, "concerns": ["list", "of", "concerns"], "risk_score": 0.0-1.0}

  Respond ONLY with the JSON object, no other text.

  """

  defp maybe_prepend_vote_format(system_content, node_attrs, graph_attrs) do
    perspective = Map.get(node_attrs, "perspective")
    mode = Map.get(graph_attrs, "mode")

    if perspective && mode == "decision" do
      @vote_format_prefix <> system_content
    else
      system_content
    end
  end

  defp maybe_use_council_question(prompt, node_attrs, graph_attrs, context) do
    perspective = Map.get(node_attrs, "perspective")
    mode = Map.get(graph_attrs, "mode")
    has_explicit_prompt = Map.has_key?(node_attrs, "prompt")

    if perspective && mode == "decision" && !has_explicit_prompt do
      # Use the council question as the prompt for decision-mode perspective nodes
      question = Context.get(context, "council.question", "")

      if question != "" do
        "Evaluate the following proposal and cast your vote:\n\n#{question}"
      else
        prompt
      end
    else
      prompt
    end
  end

  defp maybe_put_perspective_key(updates, node_attrs, response_text) do
    case Map.get(node_attrs, "perspective") do
      nil -> updates
      perspective -> Map.put(updates, "vote.#{perspective}", response_text)
    end
  end

  # Merge routing decision from process dict into context_updates.
  # Set by maybe_route_by_sensitivity when a reroute occurs.
  defp maybe_put_routing_decision(updates) do
    case Process.delete(:__routing_decision__) do
      nil -> updates
      decision -> Map.put(updates, "__routing_decision__", decision)
    end
  end

  # Propagate discovered tool names from find_tools calls into context
  # so the Session can persist them across turns.
  defp maybe_put_discovered_tools(updates) do
    case Process.delete(:__discovered_tool_names__) do
      nil ->
        updates

      names when is_list(names) and names != [] ->
        existing = Map.get(updates, "session.discovered_tool_names", [])
        Map.put(updates, "session.discovered_tool_names", existing ++ names)

      _ ->
        updates
    end
  end

  defp parse_score(nil), do: nil
  defp parse_score(value) when is_integer(value), do: value / 1
  defp parse_score(value) when is_float(value), do: value

  defp parse_score(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp parse_score(_), do: nil

  # ── Signal Emission ──────────────────────────────────────────────

  defp emit_llm_signal(event, data) do
    Builders.emit_signal(:agent, event, data)
  rescue
    _ -> :ok
  end

  # Classify errors using Arbor.AI.LLMError when available, fallback to basic map.
  defp classify_error(reason) do
    llm_error_mod = Arbor.AI.LLMError

    if Code.ensure_loaded?(llm_error_mod) and function_exported?(llm_error_mod, :classify, 1) do
      apply(llm_error_mod, :classify, [reason])
    else
      %{
        type: :unknown,
        message: inspect(reason) |> String.slice(0..200),
        status: nil,
        code: nil,
        retryable: false,
        retry_after_ms: nil,
        provider: nil
      }
    end
  end

  defp write_stage_artifacts(opts, node_id, prompt, response) do
    case Keyword.get(opts, :logs_root) do
      nil ->
        :ok

      logs_root ->
        node_dir = Path.join(logs_root, node_id)

        with :ok <- File.mkdir_p(node_dir),
             :ok <- File.write(Path.join(node_dir, "prompt.md"), prompt),
             :ok <- File.write(Path.join(node_dir, "response.md"), response) do
          :ok
        else
          _ -> :ok
        end
    end
  end

  defp maybe_record_routing_telemetry(agent_id, decision) do
    store = Arbor.Common.AgentTelemetry.Store

    if Code.ensure_loaded?(store) do
      store.record_routing(agent_id, decision)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Opt-in auto-retry for reasoning-model max-tokens-cutoff. Triggers
  # only when:
  #   1. The node's attrs say `auto_retry_on_reasoning_cutoff="true"`
  #   2. The first response had `text == ""` AND non-empty
  #      `reasoning_content` AND `finish_reason: :length` — the exact
  #      signal that the model exhausted its budget mid-CoT
  # Retries ONCE with `max_tokens * multiplier` (multiplier from
  # `auto_retry_max_tokens_multiplier`, default 2). If the retry also
  # cuts off, both warnings are appended and we give up — no recursion.
  # Operator/caller visibility: warnings on `Response.warnings` plus a
  # Logger.info line describing the decision.
  #
  # Default off because cloud reasoning models (Claude extended thinking,
  # o1, Gemini thinking) charge per token — silent doubling would be
  # surprising at scale.
  defp maybe_retry_on_reasoning_cutoff(
         {:ok, %Arbor.LLM.Response{} = raw_response} = original,
         prompt,
         node,
         context,
         graph,
         opts
       ) do
    if retry_enabled?(node) and reasoning_cutoff?(raw_response) do
      old_max_tokens = parse_int(Map.get(node.attrs, "max_tokens"), 4096)
      multiplier = parse_int(Map.get(node.attrs, "auto_retry_max_tokens_multiplier"), 2)
      new_max_tokens = old_max_tokens * multiplier

      retry_warning =
        "auto_retry: response cut off mid-reasoning at #{old_max_tokens} tokens " <>
          "(reasoning=#{byte_size(raw_response.reasoning_content || "")} bytes); " <>
          "retrying with max_tokens=#{new_max_tokens}"

      Logger.info("[LlmHandler] #{node.id}: #{retry_warning}")

      retry_node = %{node | attrs: Map.put(node.attrs, "max_tokens", to_string(new_max_tokens))}

      case call_llm(prompt, retry_node, context, graph, opts) do
        {:ok, %Arbor.LLM.Response{} = retry_response} ->
          retry_response = append_warning(retry_response, retry_warning)

          retry_response =
            if reasoning_cutoff?(retry_response) do
              second_warning =
                "auto_retry: retry also cut off mid-reasoning at #{new_max_tokens} tokens; " <>
                  "giving up (no further retries)"

              Logger.warning("[LlmHandler] #{node.id}: #{second_warning}")
              append_warning(retry_response, second_warning)
            else
              Logger.info(
                "[LlmHandler] #{node.id}: auto-retry succeeded — text=#{String.length(retry_response.text)} chars"
              )

              retry_response
            end

          {:ok, retry_response}

        {:error, reason} ->
          # Retry failed entirely — return the original response with a
          # warning explaining that the cutoff persisted because the
          # retry itself failed. The caller still sees the empty-text
          # reasoning_content and can act on it (better than a bare error
          # tuple that loses the reasoning trail).
          Logger.warning(
            "[LlmHandler] #{node.id}: auto-retry failed (#{inspect(reason, limit: 80)}); " <>
              "returning original cut-off response"
          )

          failed_warning = retry_warning <> " — retry FAILED, original response returned"
          {:ok, append_warning(raw_response, failed_warning)}
      end
    else
      original
    end
  end

  defp maybe_retry_on_reasoning_cutoff(other, _prompt, _node, _context, _graph, _opts), do: other

  defp retry_enabled?(node) do
    Map.get(node.attrs, "auto_retry_on_reasoning_cutoff") in ["true", true]
  end

  defp reasoning_cutoff?(%Arbor.LLM.Response{} = response) do
    text_empty? = response.text in [nil, ""]

    reasoning_present? =
      is_binary(response.reasoning_content) and response.reasoning_content != ""

    length_finish? = response.finish_reason == :length
    text_empty? and reasoning_present? and length_finish?
  end

  defp reasoning_cutoff?(_), do: false

  defp append_warning(%Arbor.LLM.Response{warnings: warnings} = response, msg)
       when is_list(warnings) do
    %{response | warnings: warnings ++ [msg]}
  end

  defp append_warning(%Arbor.LLM.Response{} = response, msg) do
    %{response | warnings: [msg]}
  end

  # Structural shape dump of an empty Arbor.LLM.Response — pairs with the
  # Logger.warning above so debug-mode operators can see what the model
  # actually returned without enabling verbose logging globally. Reports
  # field names + value sizes/types only; never literal text content.
  # See .arbor/roadmap/0-inbox/llm-empty-response-from-reasoning-and-mtp-models.md.
  defp log_empty_response_shape(raw_response) do
    raw_field = Map.get(raw_response, :raw)

    req_llm_shape =
      case raw_field do
        %{req_llm_response: req_response} -> summarize_req_llm_response(req_response)
        nil -> :no_raw_field
        other -> {:unexpected_raw_shape, inspect(other, limit: 80)}
      end

    Logger.debug(
      "[LlmHandler] Empty-response diagnostic: req_llm_shape=#{inspect(req_llm_shape, pretty: false, limit: :infinity)}"
    )
  end

  defp summarize_req_llm_response(req_response) when is_struct(req_response) do
    msg = Map.get(req_response, :message)

    %{
      finish_reason: Map.get(req_response, :finish_reason),
      error: presence(Map.get(req_response, :error)),
      object: presence(Map.get(req_response, :object)),
      provider_meta_keys: map_keys(Map.get(req_response, :provider_meta, %{})),
      usage_keys: map_keys(Map.get(req_response, :usage, %{})),
      message: summarize_message(msg),
      # Peek one level into the content list — the
      # `content: {:list, 1}` shape isn't enough to tell "thinking-typed
      # ContentPart" from "empty-text ContentPart". The inner type field
      # IS the discriminator that lets operators say "yep, content went
      # to reasoning, bump max_tokens" without enabling fuller logging.
      # Surfaced during 2026-06-07 probe against qwen3.6-27b-mtp +
      # gpt-oss-120b-2experts — both `type: :thinking` patterns.
      content_first: summarize_first_content_part(msg)
    }
  end

  defp summarize_req_llm_response(other), do: {:not_struct, inspect(other, limit: 60)}

  # Message structure shape — keys + value type/size, content elided.
  defp summarize_message(nil), do: :nil_message

  defp summarize_message(%{} = msg) do
    msg
    |> Map.from_struct()
    |> Enum.into(%{}, fn {k, v} -> {k, summarize_value(v)} end)
  rescue
    _ ->
      msg
      |> Enum.into(%{}, fn {k, v} -> {k, summarize_value(v)} end)
  end

  defp summarize_message(other), do: {:unexpected_message, inspect(other, limit: 60)}

  defp summarize_value(nil), do: nil
  defp summarize_value(""), do: :empty_string
  defp summarize_value(v) when is_binary(v), do: {:string, byte_size(v)}
  defp summarize_value(v) when is_list(v), do: {:list, length(v)}
  defp summarize_value(v) when is_map(v) and not is_struct(v), do: {:map_keys, map_keys(v)}
  defp summarize_value(v) when is_struct(v), do: {:struct, v.__struct__}
  defp summarize_value(v) when is_atom(v), do: v
  defp summarize_value(v) when is_number(v), do: v
  defp summarize_value(v), do: {:type, :erlang.tuple_to_list({:other, inspect(v, limit: 40)})}

  defp map_keys(m) when is_map(m), do: Map.keys(m) |> Enum.sort()
  defp map_keys(_), do: []

  # Peek into the content list's first item. Returns the inner shape
  # (struct + per-field shape) when there's at least one item; nil/empty
  # otherwise. See the comment in summarize_req_llm_response/1 for why
  # this matters.
  defp summarize_first_content_part(msg) when is_struct(msg) do
    case Map.get(msg, :content) do
      list when is_list(list) and list != [] ->
        first = hd(list)

        if is_struct(first) do
          inner =
            first
            |> Map.from_struct()
            |> Enum.into(%{}, fn {k, v} -> {k, summarize_value(v)} end)

          %{struct: first.__struct__, fields: inner}
        else
          summarize_value(first)
        end

      [] ->
        :empty_list

      _other ->
        :not_a_list
    end
  rescue
    _ -> :inspect_failed
  end

  defp summarize_first_content_part(_), do: :no_message

  defp presence(nil), do: nil
  defp presence(""), do: :empty
  defp presence(%{} = m) when map_size(m) == 0, do: :empty
  defp presence([]), do: :empty
  defp presence(_), do: :present
end
