defmodule Arbor.Actions.Acp do
  @moduledoc """
  ACP coding agent session management as Jido actions.

  Provides Jido-compatible actions for starting, messaging, querying, and
  closing ACP (Agent Communication Protocol) coding sessions. Actions wrap
  the `Arbor.AI` facade and provide capability-based authorization through
  the standard action interface.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `StartSession` | Start an ACP session and create/resume |
  | `SendMessage` | Send a coding prompt and get response |
  | `SessionStatus` | Query session health and context pressure |
  | `CloseSession` | Close session or return to pool |

  ## Examples

      # Start a session
      {:ok, result} = Arbor.Actions.Acp.StartSession.run(
        %{provider: "claude"},
        %{}
      )
      session_pid = result.session_pid

      # Send a message
      {:ok, result} = Arbor.Actions.Acp.SendMessage.run(
        %{session_pid: session_pid, prompt: "Add tests for the User module"},
        %{}
      )

  ## Authorization

  Capability URIs follow the pattern `arbor://actions/execute/acp.start_session`.
  """

  @allowed_providers [:claude, :codex, :gemini, :opencode, :goose]

  # ── Shared Helpers ──

  @doc false
  def acp_available? do
    Code.ensure_loaded?(Arbor.AI) and
      function_exported?(Arbor.AI, :acp_start_session, 2)
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

  def format_error({:invalid_provider, p}),
    do: "Unknown provider '#{p}'. Valid: #{inspect(@allowed_providers)}"

  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: "ACP error: #{inspect(reason)}"

  @doc false
  def check_context_pressure(pid) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(Arbor.AI.AcpSession, :context_pressure?, [pid])
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc false
  def get_provider(pid) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    info = apply(Arbor.AI.AcpSession, :status, [pid])
    to_string(info[:provider] || info.provider || "unknown")
  rescue
    _ -> "unknown"
  catch
    :exit, _ -> "unknown"
  end

  # ── StartSession ──

  defmodule StartSession do
    @moduledoc """
    Start an ACP coding agent session.

    Creates or resumes an ACP session with the specified provider. Optionally
    uses the session pool for efficient reuse.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `provider` | string | yes | Provider: claude, codex, gemini, opencode, goose |
    | `model` | string | no | Model override |
    | `cwd` | string | no | Working directory for the session |
    | `session_id` | string | no | Resume an existing session by ID |
    | `use_pool` | boolean | no | Checkout from pool instead of starting fresh (default: false) |
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
          doc: "Provider: claude, codex, gemini, opencode, goose"
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
        timeout: [
          type: :non_neg_integer,
          default: 120_000,
          doc: "Timeout in milliseconds"
        ]
      ]

    alias Arbor.Actions.Acp
    alias Arbor.Common.SafeAtom

    @allowed_providers [:claude, :codex, :gemini, :opencode, :goose]

    def taint_roles do
      %{
        provider: :control,
        model: :control,
        cwd: {:control, requires: [:path_traversal]},
        session_id: :control,
        prompt: {:control, requires: [:prompt_injection]},
        use_pool: :data,
        timeout: :data
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      with :ok <- Acp.require_acp!(),
           {:ok, provider} <- normalize_provider(params.provider),
           {:ok, session_pid, session_info} <- start_or_checkout(provider, params) do
        {:ok,
         %{
           session_pid: session_pid,
           session_id: session_info[:session_id] || inspect(session_pid),
           provider: to_string(provider),
           model: session_info[:model] || params[:model] || "default",
           status: "ready",
           pooled: params[:use_pool] || false
         }}
      else
        {:error, reason} -> {:error, Acp.format_error(reason)}
      end
    rescue
      e -> {:error, Acp.format_error(Exception.message(e))}
    catch
      :exit, reason -> {:error, Acp.format_error(reason)}
    end

    defp normalize_provider(provider) when is_binary(provider) do
      case SafeAtom.to_allowed(provider, @allowed_providers) do
        {:ok, atom} -> {:ok, atom}
        {:error, _} -> {:error, {:invalid_provider, provider}}
      end
    end

    defp normalize_provider(provider) when is_atom(provider) and provider in @allowed_providers,
      do: {:ok, provider}

    defp normalize_provider(provider),
      do: {:error, {:invalid_provider, inspect(provider)}}

    defp start_or_checkout(provider, %{use_pool: true} = params) do
      opts = build_opts(params)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Arbor.AI, :acp_checkout, [provider, opts]) do
        {:ok, pid} -> {:ok, pid, %{}}
        {:error, _} = error -> error
      end
    end

    defp start_or_checkout(provider, params) do
      opts = build_opts(params)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Arbor.AI, :acp_start_session, [provider, opts]) do
        {:ok, pid} -> maybe_create_or_resume(pid, params)
        {:error, _} = error -> error
      end
    end

    defp maybe_create_or_resume(pid, %{session_id: sid} = params)
         when is_binary(sid) and sid != "" do
      timeout = Map.get(params, :timeout, 120_000)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Arbor.AI, :acp_resume_session, [pid, sid, [timeout: timeout]]) do
        {:ok, info} -> {:ok, pid, info}
        {:error, _} = error -> error
      end
    end

    defp maybe_create_or_resume(pid, params) do
      opts =
        []
        |> maybe_add(:cwd, params[:cwd])
        |> maybe_add(:timeout, params[:timeout])

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Arbor.AI, :acp_create_session, [pid, opts]) do
        {:ok, info} -> {:ok, pid, info}
        {:error, _} = error -> error
      end
    end

    defp build_opts(params) do
      []
      |> maybe_add(:model, params[:model])
      |> maybe_add(:cwd, params[:cwd])
    end

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
  end

  # ── SendMessage ──

  defmodule SendMessage do
    @moduledoc """
    Send a coding prompt to an ACP session and get the response.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `session_pid` | any | yes | PID from StartSession (PID or stringified PID) |
    | `prompt` | string | yes | The coding prompt to send |
    | `timeout` | integer | no | Timeout in ms (default: 300000) |
    """

    use Jido.Action,
      name: "acp_send_message",
      description: "Send a coding prompt to an ACP session and get the response",
      category: "acp",
      tags: ["acp", "coding", "agent", "message", "prompt"],
      schema: [
        session_pid: [
          type: :any,
          required: true,
          doc: "PID from StartSession (PID or stringified PID)"
        ],
        prompt: [
          type: :string,
          required: true,
          doc: "The coding prompt to send"
        ],
        timeout: [
          type: :non_neg_integer,
          default: 300_000,
          doc: "Timeout in milliseconds"
        ]
      ]

    alias Arbor.Actions.Acp

    def taint_roles do
      %{
        session_pid: :control,
        prompt: {:control, requires: [:prompt_injection]},
        timeout: :data
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      with :ok <- Acp.require_acp!(),
           {:ok, pid} <- Acp.require_live_pid!(params.session_pid) do
        do_send(pid, params)
      end
    rescue
      e -> {:error, Acp.format_error(Exception.message(e))}
    catch
      :exit, reason -> {:error, Acp.format_error(reason)}
    end

    defp do_send(pid, params) do
      timeout = Map.get(params, :timeout, 300_000)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Arbor.AI, :acp_send_message, [pid, params.prompt, [timeout: timeout]]) do
        {:ok, response} ->
          {:ok,
           %{
             text: response[:text] || response["text"] || "",
             stop_reason: response[:stop_reason] || response["stop_reason"] || "end_turn",
             session_id: response[:session_id] || response["session_id"] || "",
             context_pressure: Acp.check_context_pressure(pid),
             usage: response[:usage] || response["usage"] || %{}
           }}

        {:error, reason} ->
          {:error, Acp.format_error(reason)}
      end
    end
  end

  # ── SessionStatus ──

  defmodule SessionStatus do
    @moduledoc """
    Query health and context pressure of an ACP session.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `session_pid` | any | yes | PID from StartSession (PID or stringified PID) |
    """

    use Jido.Action,
      name: "acp_session_status",
      description: "Query health and context pressure of an ACP session",
      category: "acp",
      tags: ["acp", "coding", "agent", "status", "health"],
      schema: [
        session_pid: [
          type: :any,
          required: true,
          doc: "PID from StartSession (PID or stringified PID)"
        ]
      ]

    alias Arbor.Actions.Acp

    def taint_roles do
      %{
        session_pid: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      with :ok <- Acp.require_acp!(),
           {:ok, pid} <- Acp.require_live_pid!(params.session_pid) do
        do_status(pid)
      end
    rescue
      e -> {:error, Acp.format_error(Exception.message(e))}
    catch
      :exit, reason -> {:error, Acp.format_error(reason)}
    end

    defp do_status(pid) do
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
  end

  # ── CloseSession ──

  defmodule CloseSession do
    @moduledoc """
    Close an ACP session or return it to the pool.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `session_pid` | any | yes | PID from StartSession (PID or stringified PID) |
    | `return_to_pool` | boolean | no | Return to pool instead of closing (default: false) |
    """

    use Jido.Action,
      name: "acp_close_session",
      description: "Close an ACP session or return it to the pool",
      category: "acp",
      tags: ["acp", "coding", "agent", "session", "close"],
      schema: [
        session_pid: [
          type: :any,
          required: true,
          doc: "PID from StartSession (PID or stringified PID)"
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
        session_pid: :control,
        return_to_pool: :data
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      with :ok <- Acp.require_acp!(),
           {:ok, pid} <- Acp.require_live_pid!(params.session_pid) do
        do_close(pid, params)
      end
    rescue
      e -> {:error, Acp.format_error(Exception.message(e))}
    catch
      :exit, reason -> {:error, Acp.format_error(reason)}
    end

    defp do_close(pid, %{return_to_pool: true}) do
      provider = Acp.get_provider(pid)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(Arbor.AI, :acp_checkin, [pid]) do
        :ok -> {:ok, %{status: "returned_to_pool", provider: provider}}
        {:error, reason} -> {:error, Acp.format_error(reason)}
      end
    end

    defp do_close(pid, _params) do
      provider = Acp.get_provider(pid)
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(Arbor.AI, :acp_close_session, [pid])
      {:ok, %{status: "closed", provider: provider}}
    end
  end
end
