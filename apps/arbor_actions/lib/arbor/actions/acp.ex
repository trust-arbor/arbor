defmodule Arbor.Actions.Acp do
  @moduledoc """
  ACP coding agent session management as Jido actions.

  Provides Jido-compatible actions for starting, messaging, querying, and
  closing ACP (Agent Communication Protocol) coding sessions. Actions wrap
  the `Arbor.AI` public facade (via `Arbor.Actions.Config.ai_module/0`) and
  provide capability-based authorization through the standard action interface.

  Managed sessions return opaque `worker_session_id` handles suitable for
  Engine context / checkpoints. PIDs never appear in public action outputs.
  Legacy `session_pid` input remains accepted for backward compatibility.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `StartSession` | Start a managed ACP session and create/resume |
  | `SendMessage` | Send a coding prompt and get response |
  | `SessionStatus` | Query session health and context pressure |
  | `CloseSession` | Close session or return to pool |

  ## Examples

      # Start a session
      {:ok, result} = Arbor.Actions.Acp.StartSession.run(
        %{provider: "claude"},
        %{}
      )
      worker_session_id = result.worker_session_id

      # Send a message
      {:ok, result} = Arbor.Actions.Acp.SendMessage.run(
        %{worker_session_id: worker_session_id, prompt: "Add tests for the User module"},
        %{}
      )

  ## Authorization

  Capability URIs follow the pattern `arbor://acp/tool`.
  """

  # Fallback allowlist used only when the Arbor.AI ACP catalog can't be reached
  # (e.g. arbor_ai not loaded). The authoritative list is the runtime catalog;
  # see allowed_providers/0. Adding an agent to `config :arbor_ai, :acp_providers`
  # is sufficient; this literal is just a degraded-mode safety net.
  @fallback_providers [:claude, :codex, :gemini, :opencode, :goose, :cursor]

  # Shared helpers

  @doc """
  The authoritative ACP provider allowlist, derived from the `Arbor.AI` catalog
  (native + adapted + `:acp_providers` config overrides). Falls back to a static
  well-known set if the catalog can't be reached.
  """
  @spec allowed_providers() :: [atom()]
  def allowed_providers do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(ai_module(), :acp_providers, []) do
      [_ | _] = providers -> providers
      _ -> @fallback_providers
    end
  rescue
    _ -> @fallback_providers
  catch
    _, _ -> @fallback_providers
  end

  @doc false
  def ai_module, do: Arbor.Actions.Config.ai_module()

  @doc false
  def acp_available? do
    mod = ai_module()

    case Code.ensure_loaded(mod) do
      {:module, loaded} ->
        function_exported?(loaded, :acp_managed_start_session, 2) or
          function_exported?(loaded, :acp_start_session, 2)

      _ ->
        false
    end
  end

  @doc false
  def require_acp! do
    if acp_available?(), do: :ok, else: {:error, format_error(:acp_not_available)}
  end

  @doc false
  def require_live_pid!(raw_pid) do
    case resolve_pid(raw_pid) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, format_error(:session_not_found)}

      nil ->
        {:error, format_error(:session_not_found)}
    end
  end

  @doc false
  # Resolve the session target from action params.
  # Prefers `worker_session_id` when present (managed handle path). Falls back to
  # legacy `session_pid` (PID or stringified PID). Manual one-of validation;
  # Jido schema cannot express exclusive-or required fields.
  def resolve_session_target(params) when is_map(params) do
    worker_id = param(params, :worker_session_id)
    pid_raw = param(params, :session_pid)

    cond do
      present_string?(worker_id) ->
        {:ok, {:worker, worker_id}}

      not is_nil(pid_raw) and pid_raw != "" ->
        case require_live_pid!(pid_raw) do
          {:ok, pid} -> {:ok, {:pid, pid}}
          error -> error
        end

      true ->
        {:error, format_error(:session_target_required)}
    end
  end

  def resolve_session_target(_), do: {:error, format_error(:session_target_required)}

  @doc false
  def authority_opts(context) when is_map(context) do
    []
    |> maybe_put(:task_id, caller_task_id(context))
    |> maybe_put(:principal_id, caller_principal_id(context))
    |> maybe_put(:agent_id, caller_principal_id(context))
  end

  def authority_opts(_), do: []

  @doc false
  # Prefer trusted AuthContext principal, then injected agent_id/principal_id.
  def caller_principal_id(context) when is_map(context) do
    case auth_context_principal_id(context) do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        param(context, :agent_id) || param(context, :principal_id)
    end
  end

  def caller_principal_id(_), do: nil

  @doc false
  def caller_task_id(context) when is_map(context) do
    param(context, :task_id) ||
      param(context, :"session.task_id") ||
      param(context, :session_task_id)
  end

  def caller_task_id(_), do: nil

  @doc false
  def resolve_pid(pid) when is_pid(pid), do: pid

  def resolve_pid(pid_string) when is_binary(pid_string) do
    # Handle stringified PIDs like "#PID<0.123.0>"
    cleaned =
      pid_string
      |> String.trim_leading("#PID")
      |> String.trim_leading("<")
      |> String.trim_trailing(">")

    try do
      :erlang.list_to_pid(~c"<#{cleaned}>")
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  def resolve_pid(_), do: nil

  @doc false
  def format_error({:unauthorized, reason}), do: "Unauthorized: #{inspect(reason)}"
  def format_error(:acp_not_available), do: "ACP is not available in this environment"
  def format_error(:session_not_found), do: "Session not found or process is dead"

  def format_error(:session_target_required),
    do: "worker_session_id or session_pid is required"

  def format_error({:invalid_provider, p}),
    do: "Unknown provider '#{p}'. Valid: #{inspect(allowed_providers())}"

  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: "ACP error: #{inspect(reason)}"

  @doc false
  # Legacy PID path only; managed path uses acp_managed_session_status.
  def check_context_pressure(pid) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(Arbor.AI.AcpSession, :context_pressure?, [pid])
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc false
  # Legacy PID path only.
  def get_provider(pid) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    info = apply(Arbor.AI.AcpSession, :status, [pid])
    to_string(info[:provider] || info.provider || "unknown")
  rescue
    _ -> "unknown"
  catch
    :exit, _ -> "unknown"
  end

  @doc false
  def param(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  def param(_map, _key), do: nil

  defp present_string?(value), do: is_binary(value) and value != ""

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp auth_context_principal_id(context) when is_map(context) do
    case Map.get(context, :auth_context) || Map.get(context, "auth_context") do
      %Arbor.Contracts.Security.AuthContext{principal_id: id}
      when is_binary(id) and id != "" ->
        id

      _ ->
        nil
    end
  end

  # StartSession

  defmodule StartSession do
    @moduledoc """
    Start an ACP coding agent session.

    Creates or resumes a **managed** ACP session with the specified provider.
    Returns a JSON-clean handle (`worker_session_id`), never a PID.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `provider` | string | yes | Provider: claude, codex, gemini, opencode, goose, cursor |
    | `model` | string | no | Model override |
    | `cwd` | string | no | Working directory for the session |
    | `session_id` | string | no | Resume an existing session by ID |
    | `use_pool` | boolean | no | Checkout from pool instead of starting fresh (default: false) |
    | `permission_mode` | string | no | Adapter permission mode: default, bypass, or deny |
    | `allowed_tools` | list | no | Adapter tool allowlist |
    | `disallowed_tools` | list | no | Adapter tool denylist |
    | `timeout` | integer | no | Timeout in ms (default: 120000) |
    """

    use Jido.Action,
      name: "acp_start_session",
      description: "Start an ACP coding agent session (Claude, Codex, Gemini, etc.)",
      category: "acp",
      tags: ["acp", "coding", "agent", "session", "start"],
      schema: [
        provider: [
          type: :string,
          required: true,
          doc: "Provider: claude, codex, gemini, grok, opencode, goose, cursor"
        ],
        model: [
          type: :string,
          doc: "Model override (e.g. 'opus', 'o3')"
        ],
        cwd: [
          type: :string,
          doc: "Working directory for the session"
        ],
        session_id: [
          type: :string,
          doc: "Resume an existing session by ID"
        ],
        use_pool: [
          type: :boolean,
          default: false,
          doc: "Checkout from pool instead of starting fresh"
        ],
        permission_mode: [
          type: :any,
          doc: "Adapter permission mode: default, bypass, or deny"
        ],
        allowed_tools: [
          type: {:list, :string},
          doc: "Adapter tool names to allow without prompting"
        ],
        disallowed_tools: [
          type: {:list, :string},
          doc: "Adapter tool names to hard-block"
        ],
        timeout: [
          type: :non_neg_integer,
          default: 120_000,
          doc: "Timeout in milliseconds"
        ]
      ]

    alias Arbor.Actions.Acp
    alias Arbor.Common.SafeAtom

    def taint_roles do
      %{
        provider: :control,
        model: :control,
        cwd: {:control, requires: [:path_traversal]},
        session_id: :control,
        prompt: {:control, requires: [:prompt_injection]},
        permission_mode: :control,
        allowed_tools: :control,
        disallowed_tools: :control,
        use_pool: :data,
        timeout: :data
      }
    end

    # Egress classification (2026-06-14 decision): an ACP session hands data to an
    # external coding agent (Claude/Codex/Gemini) we don't control: an uncontrolled
    # peer, which in turn reaches its own cloud backend. :external_peer (advisory +
    # telemetry only in 1.0; see the ACP enforcement deferral).
    def effect_class, do: :network_egress
    def egress_tier(_params, _context), do: :external_peer

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      # SECURITY (codex authz.acp-session-anonymous-file-access, HIGH): forward
      # the CALLER's agent_id into the session. Pre-fix this discarded the
      # context, so the ACP session handler initialized with agent_id=nil and
      # authorized the coding agent's file/exec callbacks as ANONYMOUS
      # (handler.ex authorize_file(nil,...) -> :ok). The identity must be
      # threaded so callbacks are authorized against the owning agent's caps.
      agent_id = caller_agent_id(context)
      task_id = Acp.caller_task_id(context)

      with :ok <- Acp.require_acp!(),
           {:ok, provider} <- normalize_provider(params.provider),
           {:ok, meta} <- managed_start(provider, params, agent_id, task_id),
           {:ok, result} <- public_start_result(meta, params, provider) do
        {:ok, result}
      else
        {:error, reason} -> {:error, Acp.format_error(reason)}
      end
    rescue
      e -> {:error, Acp.format_error(Exception.message(e))}
    catch
      :exit, reason -> {:error, Acp.format_error(reason)}
    end

    defp managed_start(provider, params, agent_id, task_id) do
      opts = build_managed_opts(params, agent_id, task_id)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(Acp.ai_module(), :acp_managed_start_session, [provider, opts])
    end

    defp public_start_result(meta, params, provider) when is_map(meta) do
      worker_session_id = map_get(meta, :worker_session_id) || map_get(meta, "worker_session_id")

      if is_binary(worker_session_id) and worker_session_id != "" do
        {:ok,
         %{
           worker_session_id: worker_session_id,
           session_id: map_get(meta, :session_id) || map_get(meta, "session_id") || "",
           provider: to_string(map_get(meta, :provider) || map_get(meta, "provider") || provider),
           model:
             to_string(
               map_get(meta, :model) || map_get(meta, "model") || params[:model] || "default"
             ),
           status: to_string(map_get(meta, :status) || map_get(meta, "status") || "ready"),
           pooled:
             truthy?(map_get(meta, :pooled) || map_get(meta, "pooled")) ||
               params[:use_pool] == true
         }}
      else
        {:error, :invalid_worker_session_handle}
      end
    end

    defp normalize_provider(provider) when is_binary(provider) do
      case SafeAtom.to_allowed(provider, Acp.allowed_providers()) do
        {:ok, atom} -> {:ok, atom}
        {:error, _} -> {:error, {:invalid_provider, provider}}
      end
    end

    defp normalize_provider(provider) when is_atom(provider) do
      if provider in Acp.allowed_providers() do
        {:ok, provider}
      else
        {:error, {:invalid_provider, inspect(provider)}}
      end
    end

    defp normalize_provider(provider),
      do: {:error, {:invalid_provider, inspect(provider)}}

    @min_sensible_timeout_ms 10_000

    defp positive_timeout_or_nil(value) do
      case value do
        t when is_integer(t) and t >= @min_sensible_timeout_ms -> t
        _ -> nil
      end
    end

    # @doc false — public so the security regression test can assert the
    # caller's agent_id is threaded into the session opts (the anonymous-access
    # bug was build_opts dropping identity).
    @doc false
    def build_opts(params, agent_id) do
      []
      |> maybe_add(:model, params[:model])
      |> maybe_add(:cwd, params[:cwd])
      |> maybe_add(:agent_id, agent_id)
      |> maybe_add_adapter_opts(params)
    end

    @doc false
    def build_managed_opts(params, agent_id, task_id) do
      params
      |> build_opts(agent_id)
      |> maybe_add(:principal_id, agent_id)
      |> maybe_add(:task_id, task_id)
      |> maybe_add(:use_pool, params[:use_pool] == true)
      |> maybe_add(:session_id, non_empty_string(params[:session_id]))
      |> maybe_add(:timeout, positive_timeout_or_nil(params[:timeout]))
    end

    @doc false
    def normalize_permission_mode(nil), do: nil
    def normalize_permission_mode(:default), do: :default
    def normalize_permission_mode(:bypass), do: :bypass
    def normalize_permission_mode(:deny), do: :deny
    def normalize_permission_mode("default"), do: :default
    def normalize_permission_mode("bypass"), do: :bypass
    def normalize_permission_mode("deny"), do: :deny
    def normalize_permission_mode(_), do: nil

    # Extract the calling agent's id from the action exec context. Tolerates
    # atom- or string-keyed contexts (Jido/engine both occur). Prefers a trusted
    # AuthContext principal when present.
    @doc false
    def caller_agent_id(context), do: Acp.caller_principal_id(context)

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, _key, false), do: opts
    defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

    defp maybe_add_adapter_opts(opts, params) do
      adapter_opts =
        []
        |> maybe_add(:permission_mode, normalize_permission_mode(params[:permission_mode]))
        |> maybe_add_tool_list(:allowed_tools, params[:allowed_tools])
        |> maybe_add_tool_list(:disallowed_tools, params[:disallowed_tools])

      case adapter_opts do
        [] -> opts
        _ -> Keyword.put(opts, :adapter_opts, adapter_opts)
      end
    end

    defp maybe_add_tool_list(opts, _key, nil), do: opts
    defp maybe_add_tool_list(opts, _key, []), do: opts

    defp maybe_add_tool_list(opts, key, tools) when is_list(tools) do
      Keyword.put(opts, key, Enum.map(tools, &to_string/1))
    end

    defp non_empty_string(value) when is_binary(value) and value != "", do: value
    defp non_empty_string(_), do: nil

    defp map_get(map, key), do: Map.get(map, key)

    defp truthy?(true), do: true
    defp truthy?(_), do: false
  end

  # SendMessage

  defmodule SendMessage do
    @moduledoc """
    Send a coding prompt to an ACP session and get the response.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `worker_session_id` | string | one-of | Managed handle from StartSession |
    | `session_pid` | any | one-of | Deprecated legacy PID (or stringified PID) |
    | `prompt` | string | yes | The coding prompt to send |
    | `timeout` | integer | no | Optional hard wall-clock timeout in ms |
    | `inactivity_timeout_ms` | integer | no | Silence window before aborting the prompt |
    """

    use Jido.Action,
      name: "acp_send_message",
      description: "Send a coding prompt to an ACP session and get the response",
      category: "acp",
      tags: ["acp", "coding", "agent", "message", "prompt"],
      schema: [
        worker_session_id: [
          type: :string,
          doc: "Managed worker handle from StartSession (preferred)"
        ],
        session_pid: [
          type: :any,
          doc: "Deprecated: legacy PID from StartSession (PID or stringified PID)"
        ],
        prompt: [
          type: :string,
          required: true,
          doc: "The coding prompt to send"
        ],
        timeout: [
          type: :non_neg_integer,
          doc: "Optional hard wall-clock timeout in milliseconds"
        ],
        inactivity_timeout_ms: [
          type: :non_neg_integer,
          doc: "Silence window before aborting the in-flight prompt"
        ]
      ]

    alias Arbor.Actions.Acp

    def taint_roles do
      %{
        worker_session_id: :control,
        session_pid: :control,
        prompt: {:control, requires: [:prompt_injection]},
        timeout: :data,
        inactivity_timeout_ms: :data
      }
    end

    # Egress classification (2026-06-14 decision): sends a coding prompt to an
    # external agent peer; see Acp.StartSession. :external_peer (advisory in 1.0).
    def effect_class, do: :network_egress
    def egress_tier(_params, _context), do: :external_peer

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      with :ok <- Acp.require_acp!(),
           {:ok, target} <- Acp.resolve_session_target(params) do
        case target do
          {:worker, worker_session_id} -> do_managed_send(worker_session_id, params, context)
          {:pid, pid} -> do_legacy_send(pid, params)
        end
      else
        {:error, reason} -> {:error, Acp.format_error(reason)}
      end
    rescue
      e -> {:error, Acp.format_error(Exception.message(e))}
    catch
      :exit, reason -> {:error, Acp.format_error(reason)}
    end

    defp do_managed_send(worker_session_id, params, context) do
      prompt = get_param(params, :prompt)

      opts =
        []
        |> maybe_add(:timeout, get_param(params, :timeout))
        |> maybe_add(:inactivity_timeout_ms, get_param(params, :inactivity_timeout_ms))
        |> Keyword.merge(Acp.authority_opts(context))

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Acp.ai_module(), :acp_managed_send_message, [worker_session_id, prompt, opts]) do
        {:ok, response} ->
          {:ok,
           %{
             text: map_get(response, :text) || map_get(response, "text") || "",
             stop_reason:
               map_get(response, :stop_reason) || map_get(response, "stop_reason") ||
                 "end_turn",
             session_id: map_get(response, :session_id) || map_get(response, "session_id") || "",
             context_pressure: managed_context_pressure(worker_session_id, context),
             usage: map_get(response, :usage) || map_get(response, "usage") || %{}
           }}

        {:error, reason} ->
          {:error, Acp.format_error(reason)}
      end
    end

    defp do_legacy_send(pid, params) do
      opts =
        []
        |> maybe_add(:timeout, get_param(params, :timeout))
        |> maybe_add(:inactivity_timeout_ms, get_param(params, :inactivity_timeout_ms))

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Acp.ai_module(), :acp_send_message, [pid, get_param(params, :prompt), opts]) do
        {:ok, response} ->
          {:ok,
           %{
             text: map_get(response, :text) || map_get(response, "text") || "",
             stop_reason:
               map_get(response, :stop_reason) || map_get(response, "stop_reason") ||
                 "end_turn",
             session_id: map_get(response, :session_id) || map_get(response, "session_id") || "",
             context_pressure: Acp.check_context_pressure(pid),
             usage: map_get(response, :usage) || map_get(response, "usage") || %{}
           }}

        {:error, reason} ->
          {:error, Acp.format_error(reason)}
      end
    end

    # Obtain context_pressure via managed status without resolving/exposing a PID.
    defp managed_context_pressure(worker_session_id, context) do
      opts = Acp.authority_opts(context)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Acp.ai_module(), :acp_managed_session_status, [worker_session_id, opts]) do
        {:ok, status} when is_map(status) ->
          map_get(status, :context_pressure) || map_get(status, "context_pressure") || false

        _ ->
          false
      end
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end

    defp get_param(params, key), do: Acp.param(params, key)

    defp map_get(map, key) when is_map(map), do: Map.get(map, key)
    defp map_get(_, _), do: nil

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
  end

  # SessionStatus

  defmodule SessionStatus do
    @moduledoc """
    Query health and context pressure of an ACP session.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `worker_session_id` | string | one-of | Managed handle from StartSession |
    | `session_pid` | any | one-of | Deprecated legacy PID (or stringified PID) |
    """

    use Jido.Action,
      name: "acp_session_status",
      description: "Query health and context pressure of an ACP session",
      category: "acp",
      tags: ["acp", "coding", "agent", "status", "health"],
      schema: [
        worker_session_id: [
          type: :string,
          doc: "Managed worker handle from StartSession (preferred)"
        ],
        session_pid: [
          type: :any,
          doc: "Deprecated: legacy PID from StartSession (PID or stringified PID)"
        ]
      ]

    alias Arbor.Actions.Acp

    def taint_roles do
      %{
        worker_session_id: :control,
        session_pid: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      with :ok <- Acp.require_acp!(),
           {:ok, target} <- Acp.resolve_session_target(params) do
        case target do
          {:worker, worker_session_id} -> do_managed_status(worker_session_id, context)
          {:pid, pid} -> do_legacy_status(pid)
        end
      else
        {:error, reason} -> {:error, Acp.format_error(reason)}
      end
    rescue
      e -> {:error, Acp.format_error(Exception.message(e))}
    catch
      :exit, reason -> {:error, Acp.format_error(reason)}
    end

    defp do_managed_status(worker_session_id, context) do
      opts = Acp.authority_opts(context)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Acp.ai_module(), :acp_managed_session_status, [worker_session_id, opts]) do
        {:ok, info} when is_map(info) ->
          {:ok,
           %{
             worker_session_id:
               map_get(info, :worker_session_id) || map_get(info, "worker_session_id") ||
                 worker_session_id,
             provider:
               to_string(map_get(info, :provider) || map_get(info, "provider") || "unknown"),
             model: to_string(map_get(info, :model) || map_get(info, "model") || "default"),
             session_id: map_get(info, :session_id) || map_get(info, "session_id") || "",
             status: to_string(map_get(info, :status) || map_get(info, "status") || "unknown"),
             context_pressure:
               map_get(info, :context_pressure) || map_get(info, "context_pressure") || false,
             context_tokens:
               map_get(info, :context_tokens) || map_get(info, "context_tokens") || 0,
             usage: map_get(info, :usage) || map_get(info, "usage") || %{},
             pooled: map_get(info, :pooled) || map_get(info, "pooled") || false
           }}

        {:error, reason} ->
          {:error, Acp.format_error(reason)}
      end
    end

    defp do_legacy_status(pid) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      info = apply(Arbor.AI.AcpSession, :status, [pid])

      {:ok,
       %{
         provider: to_string(info[:provider] || info.provider),
         model: to_string(info[:model] || info.model || "default"),
         session_id: info[:session_id] || info.session_id || "",
         status: to_string(info[:status] || info.status),
         context_pressure: Acp.check_context_pressure(pid),
         context_tokens: info[:context_tokens] || info.context_tokens || 0,
         usage: info[:usage] || info.usage || %{}
       }}
    end

    defp map_get(map, key) when is_map(map), do: Map.get(map, key)
    defp map_get(_, _), do: nil
  end

  # CloseSession

  defmodule CloseSession do
    @moduledoc """
    Close an ACP session or return it to the pool.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `worker_session_id` | string | one-of | Managed handle from StartSession |
    | `session_pid` | any | one-of | Deprecated legacy PID (or stringified PID) |
    | `return_to_pool` | boolean | no | Return to pool instead of closing (default: false) |
    """

    use Jido.Action,
      name: "acp_close_session",
      description: "Close an ACP session or return it to the pool",
      category: "acp",
      tags: ["acp", "coding", "agent", "session", "close"],
      schema: [
        worker_session_id: [
          type: :string,
          doc: "Managed worker handle from StartSession (preferred)"
        ],
        session_pid: [
          type: :any,
          doc: "Deprecated: legacy PID from StartSession (PID or stringified PID)"
        ],
        return_to_pool: [
          type: :boolean,
          default: false,
          doc: "Return to pool for reuse instead of closing"
        ]
      ]

    alias Arbor.Actions.Acp

    def taint_roles do
      %{
        worker_session_id: :control,
        session_pid: :control,
        return_to_pool: :data
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, context) do
      with :ok <- Acp.require_acp!(),
           {:ok, target} <- Acp.resolve_session_target(params) do
        case target do
          {:worker, worker_session_id} -> do_managed_close(worker_session_id, params, context)
          {:pid, pid} -> do_legacy_close(pid, params)
        end
      else
        {:error, reason} -> {:error, Acp.format_error(reason)}
      end
    rescue
      e -> {:error, Acp.format_error(Exception.message(e))}
    catch
      :exit, reason -> {:error, Acp.format_error(reason)}
    end

    defp do_managed_close(worker_session_id, params, context) do
      return_to_pool? = params[:return_to_pool] == true or params["return_to_pool"] == true

      opts =
        []
        |> Keyword.put(:return_to_pool, return_to_pool?)
        |> Keyword.merge(Acp.authority_opts(context))

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Acp.ai_module(), :acp_managed_close_session, [worker_session_id, opts]) do
        {:ok, meta} when is_map(meta) ->
          status = to_string(map_get(meta, :status) || map_get(meta, "status") || "closed")

          provider =
            case map_get(meta, :provider) || map_get(meta, "provider") do
              nil -> "unknown"
              p -> to_string(p)
            end

          result = %{
            status: status,
            provider: provider,
            worker_session_id:
              map_get(meta, :worker_session_id) || map_get(meta, "worker_session_id") ||
                worker_session_id
          }

          result =
            if Map.has_key?(meta, :active) or Map.has_key?(meta, "active") do
              Map.put(result, :active, map_get(meta, :active) || map_get(meta, "active") || false)
            else
              result
            end

          {:ok, result}

        {:error, reason} ->
          {:error, Acp.format_error(reason)}
      end
    end

    defp do_legacy_close(pid, %{return_to_pool: true}) do
      provider = Acp.get_provider(pid)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Acp.ai_module(), :acp_checkin, [pid]) do
        :ok -> {:ok, %{status: "returned_to_pool", provider: provider}}
        {:error, reason} -> {:error, Acp.format_error(reason)}
      end
    end

    defp do_legacy_close(pid, _params) do
      provider = Acp.get_provider(pid)
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(Acp.ai_module(), :acp_close_session, [pid])
      {:ok, %{status: "closed", provider: provider}}
    end

    defp map_get(map, key) when is_map(map), do: Map.get(map, key)
    defp map_get(_, _), do: nil
  end
end
