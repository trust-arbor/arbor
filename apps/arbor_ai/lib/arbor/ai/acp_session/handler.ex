defmodule Arbor.AI.AcpSession.Handler do
  @moduledoc """
  ACP Client handler for Arbor sessions.

  Implements `ExMCP.ACP.Client.Handler` behaviour, bridging ACP requests
  to Arbor's systems. Currently auto-approves all permission/file requests.
  Phase 3 will bridge these to `Arbor.Security.authorize/4`.
  """

  @behaviour ExMCP.ACP.Client.Handler

  require Logger

  defstruct [:session_pid, :agent_id, roots: []]

  @doc false
  def init(opts) do
    roots =
      case Keyword.get(opts, :cwd) do
        nil -> []
        cwd -> [%{uri: "file://#{cwd}", name: "workspace"}]
      end

    state = %__MODULE__{
      session_pid: Keyword.get(opts, :session_pid),
      agent_id: Keyword.get(opts, :agent_id),
      roots: roots
    }

    {:ok, state}
  end

  @doc false
  def handle_session_update(_session_id, _update, state) do
    # Session updates are forwarded via event_listener to the AcpSession GenServer,
    # so the handler doesn't need to do anything here.
    {:ok, state}
  end

  @doc """
  Handle permission requests from the ACP agent.

  Currently auto-approves all requests. Phase 3 will bridge to
  `Arbor.Security.authorize/4` for capability-based decisions.
  """
  def handle_permission_request(_session_id, _tool_call, _options, state) do
    Logger.debug("AcpSession.Handler: auto-approving permission request")
    {:ok, %{"outcome" => "approved"}, state}
  end

  @doc """
  Handle file read requests from the ACP agent.

  Reads the file directly. Phase 3 will add FileGuard authorization.
  """
  def handle_file_read(_session_id, path, _opts, state) do
    case File.read(path) do
      {:ok, content} -> {:ok, content, state}
      {:error, reason} -> {:error, to_string(reason), state}
    end
  end

  @doc """
  Handle file write requests from the ACP agent.

  Writes the file directly. Phase 3 will add FileGuard authorization.
  """
  def handle_file_write(_session_id, path, content, _opts, state) do
    case File.write(path, content) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, to_string(reason), state}
    end
  end

  @doc false
  def terminate(_reason, _state), do: :ok
end
