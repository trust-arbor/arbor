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

  defstruct [:session_pid, :agent_id, :workspace_root, roots: []]

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
      roots: roots
    }

    {:ok, state}
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
  def handle_permission_request(_session_id, tool_call, _options, state) do
    tool_name = Map.get(tool_call, "name") || Map.get(tool_call, :name, "unknown")
    resource_uri = "arbor://acp/tool/#{tool_name}"

    case authorize_action(state.agent_id, resource_uri, :execute) do
      :authorized ->
        {:ok, %{"outcome" => "approved"}, state}

      {:denied, reason} ->
        Logger.info("AcpSession.Handler: denied permission for #{tool_name}: #{reason}")
        {:ok, %{"outcome" => "denied", "reason" => reason}, state}
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

  # File authorization via FileGuard. When no agent_id, skip auth (system calls).
  # FileGuard does its own SafePath check internally, but we pre-check in validate_path
  # to give better error messages for workspace_root violations.
  defp authorize_file(nil, _path, _operation), do: :ok

  defp authorize_file(agent_id, path, operation) do
    if Process.whereis(Arbor.Security.CapabilityStore) do
      case Arbor.Security.FileGuard.authorize(agent_id, path, operation) do
        {:ok, _resolved} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      # CapabilityStore not running — permissive fallback
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Generic action authorization via Security.authorize/4.
  # When no agent_id, skip (system/anonymous calls).
  defp authorize_action(nil, _resource_uri, _action), do: :authorized

  defp authorize_action(agent_id, resource_uri, action) do
    # Check trust tier confirmation mode first (if available), then security authorization
    with :authorized <- check_confirmation_mode(agent_id, resource_uri),
         :authorized <- check_security_authorize(agent_id, resource_uri, action) do
      :authorized
    end
  end

  # Trust tier integration via runtime bridge (arbor_ai does not depend on arbor_trust).
  # Falls back to :authorized when Trust.Policy or Trust.Manager is unavailable.
  defp check_confirmation_mode(agent_id, resource_uri) do
    if Code.ensure_loaded?(Arbor.Trust.Policy) and
         Process.whereis(Arbor.Trust.Manager) != nil do
      case apply(Arbor.Trust.Policy, :confirmation_mode, [agent_id, resource_uri]) do
        :auto -> :authorized
        :gated -> {:denied, "requires human approval (gated by trust policy)"}
        :deny -> {:denied, "denied by trust policy"}
      end
    else
      :authorized
    end
  rescue
    _ -> :authorized
  catch
    :exit, _ -> :authorized
  end

  defp check_security_authorize(agent_id, resource_uri, action) do
    if Process.whereis(Arbor.Security.CapabilityStore) do
      case Arbor.Security.authorize(agent_id, resource_uri, action) do
        {:ok, :authorized} -> :authorized
        {:ok, :pending_approval, _id} -> {:denied, "pending human approval"}
        {:error, reason} -> {:denied, inspect(reason)}
      end
    else
      :authorized
    end
  rescue
    _ -> :authorized
  catch
    :exit, _ -> :authorized
  end

  defp format_denial(:path_traversal), do: "access denied: path traversal attempt"
  defp format_denial(:invalid_path), do: "access denied: invalid path"
  defp format_denial(:no_capability), do: "access denied: missing file capability"
  defp format_denial(:pattern_mismatch), do: "access denied: path not in allowed patterns"
  defp format_denial(:expired), do: "access denied: capability expired"
  defp format_denial(reason) when is_binary(reason), do: "access denied: #{reason}"
  defp format_denial(reason), do: "access denied: #{inspect(reason)}"
end
