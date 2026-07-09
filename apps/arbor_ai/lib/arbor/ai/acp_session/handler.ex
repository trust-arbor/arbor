defmodule Arbor.AI.AcpSession.Handler do
  @moduledoc """
  ACP Client handler for Arbor sessions.

  Implements `ExMCP.ACP.Client.Handler` behaviour, bridging ACP requests
  to Arbor's security infrastructure. Permission requests are checked via
  `Arbor.Security.authorize/4`, file operations go through
  `Arbor.Common.SafePath.resolve_within/2` + `Arbor.Security.FileGuard.authorize/3`.

  When no `workspace_root` is set, file operations are permissive (backward
  compat with sessions that don't specify a working directory). When a
  `workspace_root` is set, all file paths must resolve within it.

  Trust tier integration uses a runtime bridge since `arbor_ai` does not
  depend on `arbor_trust`.
  """

  @behaviour ExMCP.ACP.Client.Handler

  alias Arbor.Common.SafePath

  require Logger

  @default_permission_timeout_ms 60_000

  defstruct [
    :session_pid,
    :agent_id,
    :workspace_root,
    permission_timeout_ms: @default_permission_timeout_ms,
    roots: []
  ]

  @doc false
  def init(opts) do
    cwd = Keyword.get(opts, :cwd)

    roots =
      case cwd do
        nil -> []
        path -> [%{uri: "file://#{path}", name: "workspace"}]
      end

    state = %__MODULE__{
      session_pid: Keyword.get(opts, :session_pid),
      agent_id: Keyword.get(opts, :agent_id),
      workspace_root: cwd,
      permission_timeout_ms: resolve_permission_timeout(opts),
      roots: roots
    }

    {:ok, state}
  end

  # Resolution order: explicit opt > app env > module default. Both surfaces
  # stay configurable so deployments can tune (e.g. shorter for unattended
  # hosts, longer for operator-in-meeting). DOT compute nodes can plumb a
  # per-pipeline override through handler_opts down the road.
  defp resolve_permission_timeout(opts) do
    case Keyword.get(opts, :permission_timeout_ms) do
      ms when is_integer(ms) and ms > 0 ->
        ms

      _ ->
        Application.get_env(:arbor_ai, :acp_permission_timeout_ms, @default_permission_timeout_ms)
    end
  end

  @doc false
  def handle_session_update(_session_id, _update, state) do
    {:ok, state}
  end

  @doc """
  Handle permission requests from the ACP agent.

  Checks `Arbor.Security.authorize/4` with a tool-specific capability URI.
  Falls back to approved when no agent_id is set or Security is unavailable.
  """
  def handle_permission_request(_session_id, tool_call, options, state) do
    # Newer ACP spec (Gemini) carries the actual tool name on `toolCall.title`
    # or a structured field; the older shape carried `"name"`. Try both so the
    # capability URI reflects what the agent actually wants to do.
    tool_name =
      Map.get(tool_call, "name") ||
        Map.get(tool_call, :name) ||
        infer_tool_name(tool_call)

    resource_uri = "arbor://acp/tool/#{tool_name}"

    case authorize_action(state.agent_id, resource_uri, :execute, state) do
      :authorized ->
        {:ok, build_outcome(:approved, options), state}

      {:denied, reason} ->
        Logger.info("AcpSession.Handler: denied permission for #{tool_name}: #{reason}")
        {:ok, build_outcome(:rejected, options, reason), state}
    end
  end

  # ACP spec
  # (https://agentclientprotocol.com/protocol/tool-calls#permission-response)
  # requires the outcome to reference one of the offered `optionId`s:
  #
  #     {"outcome": {"outcome": "selected", "optionId": "<allowed-id>"}}
  #     {"outcome": {"outcome": "cancelled"}}
  #
  # Returning a non-spec shape (e.g. {"outcome": "approved"}) causes
  # spec-compliant agents like Gemini to ignore the response and re-ask —
  # which surfaced as the "three Signal prompts for one tool use" bug
  # during HITL smoke testing.
  defp build_outcome(decision, options, reason \\ nil)

  defp build_outcome(:approved, options, _reason) do
    case pick_option(options, ["allow_once", "allow_always"]) do
      nil ->
        # No options offered — legacy/abbreviated form. Some callers (older
        # ACP integrations, internal callers, unit tests) don't supply the
        # options list. Return the simple {"outcome": "approved"} form so
        # these paths keep working.
        %{"outcome" => "approved"}

      option_id ->
        %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}
    end
  end

  defp build_outcome(:rejected, options, reason) do
    case pick_option(options, ["reject_once", "reject_always"]) do
      nil ->
        # No options offered — same fallback as the approval path.
        %{"outcome" => "denied", "reason" => reason}

      option_id ->
        %{
          "outcome" => %{"outcome" => "selected", "optionId" => option_id},
          "reason" => reason
        }
    end
  end

  defp pick_option(options, kinds) when is_list(options) do
    Enum.find_value(kinds, fn kind ->
      Enum.find_value(options, fn opt ->
        if to_string(Map.get(opt, "kind", "")) == kind do
          Map.get(opt, "optionId")
        end
      end)
    end)
  end

  defp pick_option(_options, _kinds), do: nil

  # Newer ACP tool_call payloads (e.g. Gemini's) don't always include a
  # bare `name` field; the human-readable identifier lives in `title` or
  # is embedded in `toolCallId`. Best-effort extraction for capability
  # URIs and audit logging — falls back to "unknown" when nothing is
  # available.
  defp infer_tool_name(tool_call) when is_map(tool_call) do
    cond do
      is_binary(tool_call["title"]) -> tool_call["title"]
      is_binary(tool_call["toolCallId"]) -> extract_from_tool_call_id(tool_call["toolCallId"])
      true -> "unknown"
    end
  end

  defp infer_tool_name(_), do: "unknown"

  # Gemini's toolCallId pattern: "<tool_name>__<tool_name>_<timestamp>_<idx>"
  # e.g. "run_shell_command__run_shell_command_1780853379688_0"
  defp extract_from_tool_call_id(id) when is_binary(id) do
    case String.split(id, "__", parts: 2) do
      [name | _] when name != "" -> name
      _ -> id
    end
  end

  @doc """
  Handle file read requests from the ACP agent.

  Validates the path stays within `workspace_root` via SafePath, then checks
  FileGuard authorization before reading.
  """
  def handle_file_read(_session_id, path, _opts, state) do
    with {:ok, resolved} <- validate_path(path, state.workspace_root),
         :ok <- authorize_file(state.agent_id, resolved, :read) do
      case File.read(resolved) do
        {:ok, content} -> {:ok, content, state}
        {:error, reason} -> {:error, to_string(reason), state}
      end
    else
      {:error, reason} -> {:error, format_denial(reason), state}
    end
  end

  @doc """
  Handle file write requests from the ACP agent.

  Same path validation and authorization as reads, with `:write` operation.
  """
  def handle_file_write(_session_id, path, content, _opts, state) do
    with {:ok, resolved} <- validate_path(path, state.workspace_root),
         :ok <- authorize_file(state.agent_id, resolved, :write) do
      case File.write(resolved, content) do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, to_string(reason), state}
      end
    else
      {:error, reason} -> {:error, format_denial(reason), state}
    end
  end

  @doc false
  def terminate(_reason, _state), do: :ok

  # -- Private --

  # Path validation: when workspace_root is set, enforce SafePath bounds.
  # When no workspace_root, allow any path (backward compat).
  defp validate_path(path, nil), do: {:ok, path}

  defp validate_path(path, workspace_root) do
    case SafePath.resolve_within(path, workspace_root) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, _} = error -> error
    end
  end

  # File authorization via FileGuard.
  # FileGuard does its own SafePath check internally, but we pre-check in validate_path
  # to give better error messages for workspace_root violations.
  # @doc false — public for testability (the fail-closed regression test injects
  # a raising file_guard_module). Production callers reach it via the read/write
  # path; the head clauses must stay together so both are `def`.
  #
  # SECURITY (codex authz.acp-session-anonymous-file-access, HIGH): a nil
  # agent_id means the session was created WITHOUT a caller identity (the
  # entrypoint bug fixed in Arbor.Actions.Acp). The only caller of this function
  # is the ACP handler itself, and every real ACP session represents an owning
  # Arbor agent — there are no legitimate "system" file callbacks here. Pre-fix
  # this clause returned :ok, auto-authorizing the external coding agent's file
  # reads/writes as anonymous (bounded only by workspace_root, and UNBOUNDED
  # when no workspace_root was set). Fail closed.
  @doc false
  def authorize_file(nil, _path, _operation), do: {:error, :no_agent_identity}

  def authorize_file(agent_id, path, operation) do
    if file_security_available?() do
      case file_guard_module().authorize(agent_id, path, operation) do
        {:ok, _resolved} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      # CapabilityStore not running — permissive fallback
      :ok
    end
  rescue
    # FAIL CLOSED: a crash while checking file access must DENY, never grant.
    # (2026-06-09 Sentinel finding — the previous `:ok` auto-authorized a file
    # operation on any exception/exit from FileGuard.)
    e -> {:error, {:authorization_check_failed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:authorization_check_exited, reason}}
  end

  # Generic action authorization via Security.authorize/4.
  # SECURITY (codex authz.acp-session-anonymous-file-access, HIGH): a nil
  # agent_id means caller identity was dropped at session creation. Pre-fix this
  # returned :authorized, auto-approving the coding agent's tool/permission
  # requests anonymously. Fail closed (deny) — the same reasoning as
  # authorize_file/3 above.
  defp authorize_action(nil, _resource_uri, _action, _state),
    do: {:denied, "no agent identity (anonymous ACP session denied)"}

  defp authorize_action(agent_id, resource_uri, action, state) do
    # Check trust tier confirmation mode first (if available), then security authorization
    with :authorized <- check_confirmation_mode(agent_id, resource_uri, state),
         :authorized <- check_security_authorize(agent_id, resource_uri, action, state) do
      :authorized
    end
  end

  # Trust tier integration via runtime bridge (arbor_ai does not depend on arbor_trust).
  # Falls back to :authorized when Trust.Policy or Trust.Manager is unavailable.
  #
  # `:gated` means the trust policy says "this resource requires human
  # approval at this agent's tier" — it's the trust system's way of
  # saying "ask the human". Escalate via HITL rather than flat-denying
  # so the operator gets the same Signal/dashboard prompt as a
  # `:pending_approval` from the capability layer. Without this
  # escalation, an `:ask`-tier resource (e.g. `arbor://shell/exec/*`)
  # is unconditionally denied even when the operator is available to
  # approve it.
  defp check_confirmation_mode(agent_id, resource_uri, state) do
    if Code.ensure_loaded?(Arbor.Trust.Policy) and
         Process.whereis(Arbor.Trust.Manager) != nil do
      case apply(Arbor.Trust.Policy, :confirmation_mode, [agent_id, resource_uri]) do
        :auto ->
          :authorized

        :gated ->
          escalate_for_trust_approval(agent_id, resource_uri, state)

        :deny ->
          {:denied, "denied by trust policy"}
      end
    else
      :authorized
    end
  rescue
    _ -> :authorized
  catch
    :exit, _ -> :authorized
  end

  # Trust gate escalation. The capability layer's pending_approval path
  # already calls InteractionRouter.request inside Security.Escalation;
  # the trust gate doesn't go through Security, so we submit the
  # interaction directly here. After submission, the wait path is
  # shared with the capability-layer escalation via await_human_approval.
  defp escalate_for_trust_approval(agent_id, resource_uri, state) do
    if interaction_router_available?() do
      attrs = %{
        kind: :approval,
        agent_id: agent_id,
        user_id: operator_user_id_for(agent_id),
        description: "Trust gate: #{resource_uri} requires human approval",
        resource_uri: resource_uri,
        metadata: %{source: :trust_policy_gated}
      }

      case apply(Arbor.Comms.InteractionRouter, :request, [attrs, []]) do
        {:ok, request_id} ->
          await_human_approval(agent_id, request_id, resource_uri, state)

        {:error, reason} ->
          Logger.warning(
            "[AcpSession.Handler] trust-gate escalation failed for #{resource_uri}: #{inspect(reason)} — failing closed"
          )

          {:denied, "trust gate escalation failed: #{inspect(reason)}"}
      end
    else
      Logger.warning(
        "[AcpSession.Handler] trust-gated #{resource_uri} but InteractionRouter unavailable — failing closed"
      )

      {:denied, "trust-gated and HITL routing unavailable"}
    end
  rescue
    e ->
      Logger.warning(
        "[AcpSession.Handler] trust-gate escalation crashed for #{resource_uri}: #{Exception.message(e)}"
      )

      {:denied, "trust gate escalation crashed"}
  catch
    :exit, reason ->
      Logger.warning(
        "[AcpSession.Handler] trust-gate escalation exited for #{resource_uri}: #{inspect(reason)}"
      )

      {:denied, "trust gate escalation exited"}
  end

  defp interaction_router_available? do
    Code.ensure_loaded?(Arbor.Comms.InteractionRouter) and
      function_exported?(Arbor.Comms.InteractionRouter, :request, 2)
  end

  # Resolve the operator user_id for routing. Uses Arbor.Comms.operator_for_agent/1
  # when available (which reads the configured operator from
  # :arbor_comms, :signal, :interaction_user_id) and falls back to the
  # agent_id itself for symmetry with the legacy behavior.
  defp operator_user_id_for(agent_id) do
    if Code.ensure_loaded?(Arbor.Comms) and
         function_exported?(Arbor.Comms, :operator_for_agent, 1) do
      apply(Arbor.Comms, :operator_for_agent, [agent_id])
    else
      agent_id
    end
  end

  # @doc false — public for testability (the fail-closed regression test injects
  # a raising security_module). Production callers reach it via authorize_action.
  @doc false
  def check_security_authorize(agent_id, resource_uri, action, state) do
    if action_security_available?() do
      # `verify_identity: false` — the ACP handler is an internal caller.
      # The `agent_id` was set at `Handler.init/1` time from session opts
      # (which are locked down via signed caps for pipelines), so the
      # identity is already established by construction. The signed-
      # request gate is for external authn — ExMCP's
      # `session/request_permission` JSON-RPC doesn't carry one and
      # shouldn't need to, since the agent identity is intrinsic to the
      # session itself.
      case security_module().authorize(agent_id, resource_uri, action, verify_identity: false) do
        {:ok, :authorized} ->
          :authorized

        {:ok, :pending_approval, request_id} ->
          # Escalation already fired inside Security.authorize → Escalation
          # → InteractionRouter. Operator sees the prompt on their active
          # channel (dashboard, Signal, etc.). Block here until the operator
          # responds — that's the contract the agent expects from a
          # synchronous permission_request.
          await_human_approval(agent_id, request_id, resource_uri, state)

        {:error, reason} ->
          {:denied, inspect(reason)}
      end
    else
      :authorized
    end
  rescue
    # FAIL CLOSED: a crash while consulting security must DENY, never grant.
    # (2026-06-09 Sentinel finding — the previous `:authorized` auto-granted an
    # ACP action on any exception/exit from Security.authorize.)
    e -> {:denied, "authorization check failed: #{Exception.message(e)}"}
  catch
    :exit, reason -> {:denied, "authorization check exited: #{inspect(reason)}"}
  end

  # Security modules + availability, overridable via config for tests.
  defp security_module, do: Application.get_env(:arbor_ai, :security_module, Arbor.Security)

  defp file_guard_module,
    do: Application.get_env(:arbor_ai, :file_guard_module, Arbor.Security.FileGuard)

  defp action_security_available? do
    Application.get_env(:arbor_ai, :security_module) != nil or
      Process.whereis(Arbor.Security.CapabilityStore) != nil
  end

  defp file_security_available? do
    Application.get_env(:arbor_ai, :file_guard_module) != nil or
      Process.whereis(Arbor.Security.CapabilityStore) != nil
  end

  @doc false
  # Public for testability — production callers go through
  # check_security_authorize. Subscribes to the per-agent response topic,
  # waits for the matching request_id, and maps the operator's response
  # to a handler authorization decision. Uses a Task so subscription +
  # receive happen in a child process — non-matching messages die with
  # the Task instead of polluting the HandlerRunner GenServer's mailbox
  # (it has no catchall handle_info).
  def await_human_approval(agent_id, request_id, resource_uri, state) do
    pubsub_name = Arbor.Comms.PubSub
    timeout_ms = state.permission_timeout_ms

    # Push-notify subscribers (Signal bridge, dashboards, MCP task watchers)
    # that the ACP session has gone idle waiting for an operator decision.
    # Distinct from acp_session_completed (finished work) and inactivity timeout
    # (stuck silence → abort).
    emit_awaiting_approval(agent_id, request_id, resource_uri, state)

    if pubsub_available?(pubsub_name) do
      topic = Arbor.Contracts.Comms.Interaction.response_topic_for_agent(agent_id)

      task =
        Task.async(fn ->
          # Subscribe inside the Task — the subscription dies with the
          # Task on completion/shutdown, so stale messages cannot leak
          # into HandlerRunner's mailbox.
          Phoenix.PubSub.subscribe(pubsub_name, topic)

          receive do
            {:interaction_response, %{request_id: ^request_id, response: response}} ->
              {:response, response}
          after
            timeout_ms ->
              :timeout
          end
        end)

      # Outer yield gets a small slack window beyond the inner `after`
      # so the Task can complete its `:timeout` return before we kill it.
      case Task.yield(task, timeout_ms + 1_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:response, :approved}} ->
          Logger.info("[AcpSession.Handler] human approved #{resource_uri}")
          :authorized

        {:ok, {:response, :rejected}} ->
          Logger.info("[AcpSession.Handler] human rejected #{resource_uri}")
          {:denied, "denied by human operator"}

        {:ok, {:response, other}} ->
          Logger.warning(
            "[AcpSession.Handler] unexpected operator response for #{resource_uri}: #{inspect(other)}"
          )

          {:denied, "unexpected operator response: #{inspect(other)}"}

        {:ok, :timeout} ->
          Logger.info("[AcpSession.Handler] approval timed out for #{resource_uri}")
          {:denied, "operator did not respond in time"}

        nil ->
          # Outer yield timed out; Task.shutdown returned nil because we
          # already shut it down.
          Logger.warning(
            "[AcpSession.Handler] approval task did not respond within outer slack window for #{resource_uri}"
          )

          {:denied, "operator did not respond in time"}

        {:exit, reason} ->
          Logger.warning(
            "[AcpSession.Handler] approval task crashed for #{resource_uri}: #{inspect(reason)}"
          )

          {:denied, "approval task crashed"}
      end
    else
      # PubSub isn't running (Arbor.Comms not started in this BEAM, or test
      # scenario). Fail closed — the operator can't be reached.
      Logger.warning(
        "[AcpSession.Handler] HITL PubSub unavailable; failing closed for #{resource_uri}"
      )

      {:denied, "HITL routing unavailable"}
    end
  end

  defp pubsub_available?(name) do
    Code.ensure_loaded?(Phoenix.PubSub) and Process.whereis(name) != nil
  end

  defp emit_awaiting_approval(agent_id, request_id, resource_uri, state) do
    if Code.ensure_loaded?(Arbor.Signals) and function_exported?(Arbor.Signals, :emit, 3) do
      Arbor.Signals.emit(:agent, :acp_session_awaiting_approval, %{
        agent_id: agent_id,
        proposal_id: request_id,
        resource_uri: resource_uri,
        session_id: Map.get(state, :session_id) || Map.get(state, "session_id"),
        provider: Map.get(state, :provider) || Map.get(state, "provider"),
        source: :acp_permission
      })
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp format_denial(:path_traversal), do: "access denied: path traversal attempt"
  defp format_denial(:invalid_path), do: "access denied: invalid path"
  defp format_denial(:no_capability), do: "access denied: missing file capability"
  defp format_denial(:pattern_mismatch), do: "access denied: path not in allowed patterns"
  defp format_denial(:expired), do: "access denied: capability expired"
  defp format_denial(reason) when is_binary(reason), do: "access denied: #{reason}"
  defp format_denial(reason), do: "access denied: #{inspect(reason)}"
end
