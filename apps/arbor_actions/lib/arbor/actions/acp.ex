defmodule Arbor.Actions.Acp do
  @moduledoc """
  ACP coding agent session management as Jido actions.

  Provides Jido-compatible actions for starting, messaging, querying, and
  closing ACP (Agent Communication Protocol) coding sessions. Actions wrap
  the `Arbor.AI` public facade (via `Arbor.Actions.Config.ai_module/0`) and
  provide capability-based authorization through the standard action interface.

  Managed sessions return opaque `worker_session_id` handles suitable for
  Engine context / checkpoints. The handle is valid only while registered;
  after close, use the distinct provider `session_id` to resume a conversation
  in a newly authorized managed session. PIDs never appear in public action
  outputs. Legacy `session_pid` input remains accepted for backward
  compatibility.

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

  def format_error(:invalid_use_pool),
    do: "use_pool must be true, false, \"true\", or \"false\""

  def format_error(:invalid_fallback_to_fresh_on_resume_unavailable),
    do: "fallback_to_fresh_on_resume_unavailable must be true, false, \"true\", or \"false\""

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
    | `session_id` | string | no | Provider conversation ID to resume |
    | `use_pool` | boolean | no | Checkout from pool instead of starting fresh (default: false); DOT may serialize this as `"true"` or `"false"` |
    | `fallback_to_fresh_on_resume_unavailable` | boolean | no | Start a fresh conversation when resume is structurally unsupported (default: false); DOT may serialize this as `"true"` or `"false"` |
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
        fallback_to_fresh_on_resume_unavailable: [
          type: :boolean,
          default: false,
          doc: "Start a fresh conversation when resume is unsupported"
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
        fallback_to_fresh_on_resume_unavailable: :data,
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
    def on_before_validate_params(params) do
      with {:ok, normalized} <- normalize_use_pool_param(params),
           {:ok, normalized} <-
             normalize_fallback_to_fresh_on_resume_unavailable_param(normalized) do
        {:ok, normalized}
      else
        {:error, reason} -> {:error, Acp.format_error(reason)}
      end
    end

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

      with {:ok, params} <- normalize_use_pool_param(params),
           {:ok, params} <- normalize_fallback_to_fresh_on_resume_unavailable_param(params),
           :ok <- Acp.require_acp!(),
           {:ok, provider} <- normalize_provider(Acp.param(params, :provider)),
           {:ok, meta, continuity} <-
             managed_start_with_resume_fallback(provider, params, agent_id, task_id),
           {:ok, result} <- public_start_result(meta, params, provider, continuity) do
        {:ok, result}
      else
        {:error, reason} -> {:error, Acp.format_error(reason)}
      end
    rescue
      e -> {:error, Acp.format_error(Exception.message(e))}
    catch
      :exit, reason -> {:error, Acp.format_error(reason)}
    end

    defp managed_start_with_resume_fallback(provider, params, agent_id, task_id) do
      opts = build_managed_opts(params, agent_id, task_id)
      resume_requested? = non_empty_string(params[:session_id]) != nil

      case managed_start(provider, opts) do
        {:ok, meta} ->
          {:ok, meta, if(resume_requested?, do: "resumed", else: "new")}

        {:error, reason} ->
          case {resume_requested?, Map.get(params, :fallback_to_fresh_on_resume_unavailable)} do
            {true, true} ->
              if Arbor.AI.classify_resume_unavailability(reason) == :resume_unavailable do
                fallback_opts =
                  params
                  |> Map.delete(:session_id)
                  |> build_managed_opts(agent_id, task_id)
                  |> Keyword.put(:create_session, true)

                case managed_start(provider, fallback_opts) do
                  {:ok, meta} -> {:ok, meta, "fresh_recovery"}
                  {:error, fallback_reason} -> {:error, fallback_reason}
                end
              else
                {:error, reason}
              end

            _ ->
              {:error, reason}
          end
      end
    end

    defp managed_start(provider, opts) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(Acp.ai_module(), :acp_managed_start_session, [provider, opts])
    end

    defp public_start_result(meta, params, provider, continuity) when is_map(meta) do
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
               params[:use_pool] == true,
           continuity: continuity
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
    def normalize_use_pool_param(params) when is_map(params) do
      case {Map.fetch(params, :use_pool), Map.fetch(params, "use_pool")} do
        {:error, :error} ->
          {:ok, Map.put(params, :use_pool, false)}

        {{:ok, _atom_value}, {:ok, _string_value}} ->
          {:error, :invalid_use_pool}

        {{:ok, value}, :error} ->
          put_normalized_use_pool(params, value)

        {:error, {:ok, value}} ->
          params
          |> Map.delete("use_pool")
          |> put_normalized_use_pool(value)
      end
    end

    def normalize_use_pool_param(_params), do: {:error, :invalid_use_pool}

    @doc false
    def normalize_use_pool(value) when is_boolean(value), do: {:ok, value}
    def normalize_use_pool("true"), do: {:ok, true}
    def normalize_use_pool("false"), do: {:ok, false}
    def normalize_use_pool(_value), do: {:error, :invalid_use_pool}

    @doc false
    def normalize_fallback_to_fresh_on_resume_unavailable_param(params) when is_map(params) do
      key = :fallback_to_fresh_on_resume_unavailable
      string_key = Atom.to_string(key)

      case {Map.fetch(params, key), Map.fetch(params, string_key)} do
        {:error, :error} ->
          {:ok, Map.put(params, key, false)}

        {{:ok, _atom_value}, {:ok, _string_value}} ->
          {:error, :invalid_fallback_to_fresh_on_resume_unavailable}

        {{:ok, value}, :error} ->
          put_normalized_fallback_to_fresh_on_resume_unavailable(params, value)

        {:error, {:ok, value}} ->
          params
          |> Map.delete(string_key)
          |> put_normalized_fallback_to_fresh_on_resume_unavailable(value)
      end
    end

    def normalize_fallback_to_fresh_on_resume_unavailable_param(_params),
      do: {:error, :invalid_fallback_to_fresh_on_resume_unavailable}

    @doc false
    def normalize_fallback_to_fresh_on_resume_unavailable(value) when is_boolean(value),
      do: {:ok, value}

    def normalize_fallback_to_fresh_on_resume_unavailable("true"), do: {:ok, true}
    def normalize_fallback_to_fresh_on_resume_unavailable("false"), do: {:ok, false}

    def normalize_fallback_to_fresh_on_resume_unavailable(_value),
      do: {:error, :invalid_fallback_to_fresh_on_resume_unavailable}

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

    defp put_normalized_use_pool(params, value) do
      case normalize_use_pool(value) do
        {:ok, normalized} -> {:ok, Map.put(params, :use_pool, normalized)}
        {:error, _reason} = error -> error
      end
    end

    defp put_normalized_fallback_to_fresh_on_resume_unavailable(params, value) do
      case normalize_fallback_to_fresh_on_resume_unavailable(value) do
        {:ok, normalized} ->
          {:ok, Map.put(params, :fallback_to_fresh_on_resume_unavailable, normalized)}

        {:error, _reason} = error ->
          error
      end
    end

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
          status = managed_status(worker_session_id, context)

          # Preserve the ACP stop_reason fact. Never default missing/blank values
          # to "end_turn" — owner graphs must gate on an explicit trusted end_turn.
          {:ok,
           %{
             text: map_get(response, :text) || map_get(response, "text") || "",
             stop_reason: normalize_stop_reason(response),
             session_id: provider_session_id(response, status),
             context_pressure:
               map_get(status, :context_pressure) || map_get(status, "context_pressure") || false,
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
             stop_reason: normalize_stop_reason(response),
             session_id: map_get(response, :session_id) || map_get(response, "session_id") || "",
             context_pressure: Acp.check_context_pressure(pid),
             usage: map_get(response, :usage) || map_get(response, "usage") || %{}
           }}

        {:error, reason} ->
          {:error, Acp.format_error(reason)}
      end
    end

    # Keep missing/blank stop_reason as "" (not a defaulted "end_turn") so
    # JSON-clean consumers and graph conditions can distinguish omission from a
    # trusted end_turn. Empty string is Engine-condition-safe (nil is not).
    defp normalize_stop_reason(response) when is_map(response) do
      case map_get(response, :stop_reason) || map_get(response, "stop_reason") do
        reason when is_binary(reason) ->
          String.trim(reason)

        reason when is_atom(reason) and not is_nil(reason) ->
          Atom.to_string(reason)

        _ ->
          ""
      end
    end

    # Obtain continuity and pressure through the owner-bound managed facade
    # without resolving or exposing a PID.
    defp managed_status(worker_session_id, context) do
      opts = Acp.authority_opts(context)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Acp.ai_module(), :acp_managed_session_status, [worker_session_id, opts]) do
        {:ok, status} when is_map(status) -> status
        _ -> %{}
      end
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end

    defp provider_session_id(response, status) do
      [
        map_get(response, :session_id),
        map_get(response, "session_id"),
        map_get(status, :session_id),
        map_get(status, "session_id")
      ]
      |> Enum.find("", &(is_binary(&1) and &1 != ""))
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

    @max_usage_entries 32
    @max_usage_list_items 32
    @max_usage_depth 3
    @max_usage_key_bytes 128
    @max_usage_string_bytes 1_024
    @max_usage_encoded_bytes 16_384

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
      status_snapshot = managed_status_snapshot(worker_session_id, context)

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

          {:ok, add_final_session_metrics(result, status_snapshot)}

        {:error, reason} ->
          {:error, Acp.format_error(reason)}
      end
    end

    # Closing invalidates the live status source, so capture cumulative usage
    # immediately beforehand. Status is observational: any failure must not
    # prevent the authoritative close/check-in operation from running.
    defp managed_status_snapshot(worker_session_id, context) do
      opts = Acp.authority_opts(context)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Acp.ai_module(), :acp_managed_session_status, [worker_session_id, opts]) do
        {:ok, status} when is_map(status) and not is_struct(status) -> status
        _ -> nil
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end

    defp add_final_session_metrics(result, status_snapshot)
         when is_map(result) and not is_struct(result) and is_map(status_snapshot) do
      result
      |> maybe_put_usage(status_snapshot)
      |> maybe_put_context_tokens(status_snapshot)
    end

    defp add_final_session_metrics(result, _status_snapshot), do: result

    defp maybe_put_usage(result, status_snapshot) do
      status_snapshot
      |> then(&(map_get(&1, :usage) || map_get(&1, "usage")))
      |> clean_usage()
      |> case do
        usage when is_map(usage) and map_size(usage) > 0 -> Map.put(result, :usage, usage)
        _ -> result
      end
    end

    defp maybe_put_context_tokens(result, status_snapshot) do
      case map_get(status_snapshot, :context_tokens) ||
             map_get(status_snapshot, "context_tokens") do
        tokens when is_integer(tokens) and tokens >= 0 ->
          Map.put(result, :context_tokens, tokens)

        _ ->
          result
      end
    end

    defp clean_usage(%_{}), do: nil

    defp clean_usage(usage) when is_map(usage) do
      with {:ok, clean} <- clean_usage_map(usage, 0),
           true <- map_size(clean) > 0,
           {:ok, encoded} <- Jason.encode(clean),
           true <- byte_size(encoded) <= @max_usage_encoded_bytes do
        clean
      else
        _ -> nil
      end
    rescue
      _ -> nil
    end

    defp clean_usage(_usage), do: nil

    defp clean_usage_map(map, depth) when depth <= @max_usage_depth do
      entries =
        map
        |> Enum.reduce([], fn {key, value}, acc ->
          with {clean_key, rank} <- clean_usage_key(key),
               {:ok, clean_value} <- clean_usage_value(value, depth + 1) do
            [{clean_key, rank, clean_value} | acc]
          else
            _ -> acc
          end
        end)
        |> Enum.sort_by(fn {key, rank, _value} -> {key, rank} end)
        |> Enum.uniq_by(fn {key, _rank, _value} -> key end)
        |> Enum.take(@max_usage_entries)

      {:ok, Map.new(entries, fn {key, _rank, value} -> {key, value} end)}
    end

    defp clean_usage_map(_map, _depth), do: :drop

    defp clean_usage_key(key) when is_binary(key) do
      if String.valid?(key) and byte_size(key) <= @max_usage_key_bytes,
        do: {key, 0},
        else: nil
    end

    defp clean_usage_key(key) when is_atom(key) do
      clean_usage_key(Atom.to_string(key))
      |> case do
        {clean, _rank} -> {clean, 1}
        nil -> nil
      end
    end

    defp clean_usage_key(_key), do: nil

    defp clean_usage_value(_value, depth) when depth > @max_usage_depth, do: :drop

    defp clean_usage_value(value, _depth)
         when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
         do: {:ok, value}

    defp clean_usage_value(value, _depth) when is_binary(value) do
      if String.valid?(value) and byte_size(value) <= @max_usage_string_bytes,
        do: {:ok, value},
        else: :drop
    end

    defp clean_usage_value(value, depth) when is_atom(value) do
      clean_usage_value(Atom.to_string(value), depth)
    end

    defp clean_usage_value(%_{}, _depth), do: :drop

    defp clean_usage_value(map, depth) when is_map(map), do: clean_usage_map(map, depth)

    defp clean_usage_value(list, depth) when is_list(list) do
      clean =
        list
        |> Enum.take(@max_usage_list_items)
        |> Enum.reduce([], fn value, acc ->
          case clean_usage_value(value, depth + 1) do
            {:ok, clean_value} -> [clean_value | acc]
            :drop -> acc
          end
        end)
        |> Enum.reverse()

      {:ok, clean}
    end

    defp clean_usage_value(_value, _depth), do: :drop

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
