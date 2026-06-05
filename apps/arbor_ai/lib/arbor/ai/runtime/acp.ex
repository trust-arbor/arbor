defmodule Arbor.AI.Runtime.Acp do
  @moduledoc """
  Subprocess CLI runtime — drives turns through a CLI agent via the ACP
  protocol (`Arbor.AI.AcpPool` + `Arbor.AI.AcpSession`).

  The CLI binary is derived from `request.provider`. Today's mapping:

    | provider                              | CLI       |
    |---------------------------------------|-----------|
    | `"anthropic"`                         | `:claude` |
    | `"openai"`                            | `:codex`  |
    | `"google"`, `"google_vertex"`         | `:gemini` |

  Providers without a known CLI mapping return
  `{:error, {:no_cli_for_provider, provider}}` rather than guessing.

  ## Why this exists separately from `Arbor.AI.LLM.Adapter.Acp`

  The existing `Adapter.Acp` reads the CLI from `request.provider_options.agent`
  — that's the pre-runtime-axis shape where `provider: "acp"` meant "use
  the ACP adapter" and the agent was a side-channel option. Phase 2c
  makes `provider` name the actual model source (`:anthropic`) and
  `runtime: :acp` name the execution path. `Runtime.Acp` is the new
  surface; `Adapter.Acp` is `@deprecated` (kept working for legacy
  callers that hit `Client.complete` directly).

  Internally we still go through `AcpPool` and `AcpSession.send_message/3`
  — the pool semantics (checkout, idle cleanup, crash recovery) are
  the right shape and aren't being rewritten here. We just resolve
  the CLI from the new axis.
  """

  @behaviour Arbor.AI.Runtime

  alias Arbor.AI.Runtime
  alias Arbor.Contracts.AI.RuntimeProfile
  alias Arbor.LLM.Request
  alias Arbor.LLM.Response

  require Logger

  @default_timeout :infinity

  # Provider → CLI binary mapping. Limited to providers Arbor knows how
  # to spawn a real CLI for. Bedrock/Vertex/Anthropic models served via
  # OpenRouter etc. don't have a generic "OpenRouter CLI" — those go
  # through `:arbor` runtime instead.
  @provider_to_cli %{
    "anthropic" => :claude,
    "openai" => :codex,
    "google" => :gemini,
    "google_vertex" => :gemini,
    "google_vertex_anthropic" => :claude
  }

  # Runtime bridges — same shape as Adapter.Acp uses, kept for clarity
  # that the pool semantics are unchanged.
  @pool_mod Arbor.AI.AcpPool
  @session_mod Arbor.AI.AcpSession

  @impl Runtime
  @spec prepare(Request.t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def prepare(%Request{provider: provider} = request, _opts) do
    case Map.get(@provider_to_cli, provider) do
      nil ->
        {:error, {:no_cli_for_provider, provider}}

      _cli ->
        # Pass the request through unchanged — execute/3 will re-resolve
        # the CLI from request.provider. Splitting resolution between
        # prepare and execute kept the boundary clean against `Runtime`
        # callbacks calling each other directly.
        {:ok, request}
    end
  end

  @impl Runtime
  @spec execute(Request.t(), Runtime.callbacks(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def execute(%Request{} = request, _callbacks, opts) do
    with {:ok, cli} <- resolve_cli(request),
         {:ok, session} <- pool_checkout(cli, build_checkout_opts(request, opts)) do
      timeout = Keyword.get(opts, :timeout, @default_timeout)
      result = session_prompt(session, request, timeout)
      _ = pool_checkin(session)

      case result do
        {:ok, raw} -> {:ok, format_response(raw, cli)}
        {:error, _} = err -> err
      end
    end
  end

  @impl Runtime
  @spec profile() :: RuntimeProfile.t()
  def profile do
    {:ok, p} =
      RuntimeProfile.new(%{
        runtime_id: :acp,
        display_name: "ACP (CLI subprocess via AcpPool)",
        # The CLI subprocess owns the turn loop — Arbor sends a prompt
        # and waits for the response. Retries and tool continuation are
        # the CLI's responsibility.
        owns_model_loop: false,
        # The CLI maintains its own thread; Arbor mirrors history into
        # its own stores but isn't the canonical owner.
        owns_thread_history: false,
        # Jido + native tools + action hooks live in the BEAM. The CLI
        # has its own tool surface that doesn't compose with these.
        supports_jido_actions: false,
        supports_action_hooks: false,
        supports_native_tools: false,
        # Arbor's context engine + compaction can mirror but doesn't
        # drive what the CLI runs — these are downgraded to "false" here
        # rather than overclaiming partial support.
        runs_context_engine: false,
        exposes_compaction_data: false,
        unsupported_features: [
          :jido_actions,
          :action_hooks,
          :native_tools,
          :context_engine,
          :compaction_data
        ]
      })

    p
  end

  # -- Internals --

  defp resolve_cli(%Request{provider: provider}) do
    case Map.get(@provider_to_cli, provider) do
      nil -> {:error, {:no_cli_for_provider, provider}}
      cli -> {:ok, cli}
    end
  end

  @doc false
  # Exposed (under @doc false) so tests can pin the
  # provider_options → checkout-opts shape without needing a live
  # AcpPool. Public callers should not depend on this.
  def build_checkout_opts(%Request{} = request, opts) do
    opts
    |> Keyword.put(:model, request.model)
    |> Keyword.put(:timeout, Keyword.get(opts, :timeout, @default_timeout))
    |> maybe_add(:workspace, Map.get(request.provider_options, "workspace"))
    |> maybe_add(
      :agent_id,
      Map.get(request.provider_options, "agent_id") || opts[:agent_id]
    )
    |> maybe_add(:capabilities, Map.get(request.provider_options, "capabilities"))
    |> maybe_add(:tool_modules, Map.get(request.provider_options, "tool_modules"))
  end

  defp pool_checkout(cli, opts) do
    if Code.ensure_loaded?(@pool_mod) and is_pid(Process.whereis(@pool_mod)) do
      apply(@pool_mod, :checkout, [cli, opts])
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

  defp session_prompt(session, %Request{} = request, timeout) do
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

  defp extract_prompt(%Request{messages: messages}) do
    messages
    |> Enum.filter(fn msg -> msg.role == :user end)
    |> List.last()
    |> case do
      nil -> ""
      msg -> extract_text(msg.content)
    end
  end

  defp extract_system_prompt(%Request{messages: messages}) do
    messages
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

  @doc false
  # Exposed (under @doc false) so tests can pin the ACP-result → Response
  # shape conversion without needing a live AcpPool / AcpSession. Public
  # callers should not depend on this — it's adapter-internal.
  def format_response(result, cli) when is_map(result) do
    text = Map.get(result, "text") || Map.get(result, :text, "")
    stop_reason = Map.get(result, "stopReason") || Map.get(result, :stop_reason)
    usage = Map.get(result, "usage") || Map.get(result, :usage, %{})
    session_id = Map.get(result, "sessionId") || Map.get(result, :session_id)
    thinking = normalize_thinking(Map.get(result, "thinking") || Map.get(result, :thinking))

    finish_reason =
      case stop_reason do
        "end_turn" -> :stop
        "max_tokens" -> :length
        "tool_use" -> :tool_calls
        _ -> :stop
      end

    %Response{
      text: text,
      thinking: thinking,
      session_id: session_id,
      finish_reason: finish_reason,
      content_parts: [],
      usage: normalize_usage(usage),
      warnings: [],
      raw: %{cli: to_string(cli), result: result}
    }
  end

  # Convert ex_mcp's `"thinking" => [%{"text" => ..., "signature" => ...}]`
  # shape into the atom-keyed `thinking_block()` typespec on Response.
  # Returns nil when the field is absent or empty so consumers can
  # `is_nil?/1`-check rather than walking an empty list.
  defp normalize_thinking(nil), do: nil
  defp normalize_thinking([]), do: nil

  defp normalize_thinking(blocks) when is_list(blocks) do
    Enum.map(blocks, fn block ->
      %{
        text: Map.get(block, "text") || Map.get(block, :text, ""),
        signature: Map.get(block, "signature") || Map.get(block, :signature)
      }
    end)
  end

  defp normalize_thinking(_), do: nil

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens, 0),
      total_tokens: Map.get(usage, "total_tokens") || Map.get(usage, :total_tokens, 0)
    }
  end

  defp normalize_usage(_),
    do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp maybe_add(kw, _key, nil), do: kw
  defp maybe_add(kw, key, value), do: Keyword.put(kw, key, value)
end
