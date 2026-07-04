defmodule Arbor.Agent.Prototypes.XaiVoiceOrchestrator do
  @moduledoc """
  PROTOTYPE (text-driven, no audio yet): proves the xAI Voice Agent orchestration loop end to end.

  Connects to xAI's realtime WebSocket (`wss://api.x.ai/v1/realtime`) authenticated with our
  subscription OAuth token (`Arbor.LLM.OAuth`), declares a `delegate_to_agent` **function** tool,
  sends a TEXT prompt, and drives the tool loop:

      response.function_call_arguments.done  →  launch a CLI agent (Codex/Claude) via ACP
                                             →  conversation.item.create (function_call_output)
                                             →  response.create  →  final spoken/text answer

  So the voice-agent "brain" decides to delegate, Arbor launches a real CLI agent over ACP
  (`Arbor.AI.acp_*` — the verified path), runs the task, and feeds the result back. Audio I/O
  (mic capture / speaker playback) is deliberately OUT of scope — a separate, orthogonal layer.

      iex> Arbor.Agent.Prototypes.XaiVoiceOrchestrator.demo(
      ...>   "Ask the codex agent to write a one-line Elixir hello world, then tell me what it wrote."
      ...> )
      {:ok, %{text: "...", delegations: [%{provider: "codex", task: "...", output: "..."}]}}

  Text output is requested via `modalities: ["text"]`; we also accumulate audio-transcript deltas as
  a fallback, so we capture the answer regardless of the server's chosen modality.
  """

  require Logger

  alias Arbor.LLM.OAuth

  @host "api.x.ai"
  @port 443
  @path "/v1/realtime?model=grok-voice-latest"
  @recv_timeout 90_000
  @acp_timeout 180_000
  @tool_name "delegate_to_agent"

  @spec demo(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def demo(prompt, _opts \\ []) do
    with {:ok, token} <- OAuth.access_token(:xai),
         {:ok, delegate_id} <- mint_delegate_agent(),
         {:ok, sock} <- connect(token) do
      try do
        sock
        |> send_json(session_update())
        |> send_json(user_text(prompt))
        |> send_json(%{"type" => "response.create"})
        |> loop(%{text: "", delegations: [], delegate_id: delegate_id, pending_tool: false})
      after
        Arbor.Agent.Manager.stop_agent(delegate_id)
      end
    end
  end

  # ── realtime protocol messages ──

  defp session_update do
    %{
      "type" => "session.update",
      "session" => %{
        "modalities" => ["text"],
        "turn_detection" => nil,
        "instructions" =>
          "You are Arbor's voice front desk. When the user asks to have a coding or engineering " <>
            "task done, call the delegate_to_agent tool with a `provider` (\"codex\" or \"claude\") " <>
            "and a clear `task`. After the tool returns, tell the user what the agent produced in " <>
            "one or two sentences.",
        "tools" => [
          %{
            "type" => "function",
            "name" => @tool_name,
            "description" =>
              "Delegate a coding/engineering task to a CLI agent (Codex or Claude Code) over ACP. " <>
                "Returns the agent's result text.",
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "provider" => %{
                  "type" => "string",
                  "enum" => ["codex", "claude"],
                  "description" => "Which CLI agent to launch"
                },
                "task" => %{"type" => "string", "description" => "The task/prompt for the agent"}
              },
              "required" => ["provider", "task"]
            }
          }
        ]
      }
    }
  end

  defp user_text(text) do
    %{
      "type" => "conversation.item.create",
      "item" => %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => text}]
      }
    }
  end

  defp function_output(call_id, output) do
    %{
      "type" => "conversation.item.create",
      "item" => %{"type" => "function_call_output", "call_id" => call_id, "output" => output}
    }
  end

  # ── event loop ──

  defp loop(sock, acc) do
    case recv_event(sock) do
      {:ok, sock, %{"type" => type} = event} -> handle(type, event, sock, acc)
      {:error, reason} -> {:error, {:recv, reason, %{text: acc.text, delegations: acc.delegations}}}
    end
  end

  # The model wants to delegate → run the CLI agent via ACP, feed the result back, ask for more.
  defp handle("response.function_call_arguments.done", event, sock, acc) do
    args = decode_json(event["arguments"])
    provider = args["provider"] || "codex"
    task = args["task"] || ""
    Logger.info("[VoiceOrch] delegate → #{provider}: #{String.slice(task, 0, 80)}")
    output = run_acp(provider, task, acc.delegate_id)

    acc = %{
      acc
      | delegations: acc.delegations ++ [%{provider: provider, task: task, output: output}],
        pending_tool: true
    }

    sock
    |> send_json(function_output(event["call_id"], output))
    |> send_json(%{"type" => "response.create"})
    |> loop(acc)
  end

  # Text (or the transcript of spoken audio) — accumulate either.
  defp handle(type, event, sock, acc)
       when type in ["response.output_text.delta", "response.output_audio_transcript.delta"] do
    loop(sock, %{acc | text: acc.text <> (event["delta"] || "")})
  end

  # A response completed. If it was the tool-call response, keep going for the follow-up answer;
  # otherwise this is the final answer — return.
  defp handle("response.done", _event, sock, %{pending_tool: true} = acc) do
    loop(sock, %{acc | pending_tool: false})
  end

  defp handle("response.done", _event, _sock, acc) do
    {:ok, %{text: String.trim(acc.text), delegations: acc.delegations}}
  end

  defp handle("error", event, _sock, acc) do
    {:error, {:server_error, event["error"], %{text: acc.text, delegations: acc.delegations}}}
  end

  defp handle(_type, _event, sock, acc), do: loop(sock, acc)

  # ── the tool: launch a CLI agent via ACP (the verified path) ──

  defp run_acp(provider, task, delegate_id) do
    cwd = File.cwd!()

    with {:ok, session} <-
           Arbor.AI.acp_start_session(acp_provider(provider),
             timeout: @acp_timeout,
             agent_id: delegate_id
           ),
         {:ok, _created} <- Arbor.AI.acp_create_session(session, cwd: cwd),
         {:ok, response} <- Arbor.AI.acp_send_message(session, task, timeout: @acp_timeout) do
      Arbor.AI.acp_close_session(session)
      response[:text] || response["text"] || "(agent returned no text)"
    else
      {:error, reason} -> "[delegation failed: #{inspect(reason)}]"
    end
  end

  # acp_start_session expects an atom provider (:codex/:claude/:grok), matching @native_providers.
  defp acp_provider("claude"), do: :claude
  defp acp_provider("grok"), do: :grok
  defp acp_provider(_), do: :codex

  # ── minimal ACP-capable delegate identity (for AcpSession.Handler authorization) ──

  defp mint_delegate_agent do
    name = "voice-delegate-#{System.unique_integer([:positive, :monotonic])}"

    model_config = %{
      id: "gpt-5.4-mini",
      provider: :openai_oauth,
      runtime: :arbor,
      module: Arbor.Agent.APIAgent,
      start_opts: []
    }

    start_opts = [template: "researcher", display_name: name, model_config: model_config, tools: []]

    case Arbor.Agent.Manager.start_or_resume(Arbor.Agent.APIAgent, name, start_opts) do
      {:ok, agent_id, _pid} ->
        grant_acp_caps(agent_id)
        {:ok, agent_id}

      {:error, reason} ->
        {:error, {:delegate_agent_create_failed, reason}}
    end
  end

  defp grant_acp_caps(agent_id) do
    cwd = File.cwd!()
    Arbor.Security.grant(principal: agent_id, resource: "arbor://acp/tool/**")
    Arbor.Security.grant(principal: agent_id, resource: "arbor://fs/read/#{String.trim_leading(cwd, "/")}/**")
    Arbor.Security.grant(principal: agent_id, resource: "arbor://fs/list/#{String.trim_leading(cwd, "/")}/**")
    Arbor.Security.grant(principal: agent_id, resource: "arbor://fs/write/#{String.trim_leading(cwd, "/")}/**")

    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | baseline: :allow}
      |> Arbor.Trust.Authority.set_rule("arbor://acp/tool", :allow)
    end)

    :ok
  end

  # ── Mint WebSocket plumbing ──

  defp connect(token) do
    with {:ok, conn} <- Mint.HTTP.connect(:https, @host, @port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(:wss, conn, @path, [{"authorization", "Bearer " <> token}]),
         {:ok, conn, status, headers} <- await_upgrade(conn, ref, nil, nil),
         {:ok, conn, ws} <- Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, %{conn: conn, ref: ref, ws: ws, pending: []}}
    end
  end

  defp await_upgrade(conn, ref, status, headers) do
    receive do
      msg ->
        case Mint.WebSocket.stream(conn, msg) do
          {:ok, conn, resps} ->
            status = Enum.find_value(resps, status, fn {:status, ^ref, s} -> s; _ -> nil end)
            headers = Enum.find_value(resps, headers, fn {:headers, ^ref, h} -> h; _ -> nil end)

            if Enum.any?(resps, &match?({:done, ^ref}, &1)),
              do: {:ok, conn, status, headers},
              else: await_upgrade(conn, ref, status, headers)

          {:error, _conn, reason, _} ->
            {:error, {:upgrade_failed, reason}}
        end
    after
      @recv_timeout -> {:error, :upgrade_timeout}
    end
  end

  defp send_json(sock, msg) do
    {:ok, ws, data} = Mint.WebSocket.encode(sock.ws, {:text, Jason.encode!(msg)})
    {:ok, conn} = Mint.WebSocket.stream_request_body(sock.conn, sock.ref, data)
    %{sock | ws: ws, conn: conn}
  end

  # Return the next decoded JSON event, buffering extra events that arrived in the same batch.
  defp recv_event(%{pending: [event | rest]} = sock), do: {:ok, %{sock | pending: rest}, event}

  defp recv_event(sock) do
    receive do
      msg ->
        case Mint.WebSocket.stream(sock.conn, msg) do
          {:ok, conn, resps} ->
            sock = %{sock | conn: conn}
            data = for {:data, r, d} <- resps, r == sock.ref, into: <<>>, do: d

            if data == <<>> do
              recv_event(sock)
            else
              {:ok, ws, frames} = Mint.WebSocket.decode(sock.ws, data)
              events = for {:text, p} <- frames, {:ok, m} <- [Jason.decode(p)], is_map(m), do: m

              case events do
                [] -> recv_event(%{sock | ws: ws})
                [first | rest] -> {:ok, %{sock | ws: ws, pending: rest}, first}
              end
            end

          {:error, _conn, reason, _} ->
            {:error, reason}
        end
    after
      @recv_timeout -> {:error, :recv_timeout}
    end
  end

  defp decode_json(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  defp decode_json(_), do: %{}
end
