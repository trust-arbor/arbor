defmodule Arbor.Gateway.MCP.ClientSupervisor do
  @moduledoc """
  DynamicSupervisor managing MCP client connections.

  Each connected MCP server runs as a supervised `ClientConnection` process.
  Connections automatically reconnect on failure via OTP supervision.

  ## Usage

      # Connect to an MCP server
      {:ok, pid} = ClientSupervisor.start_connection("github", %{
        transport: :stdio,
        command: ["npx", "-y", "@modelcontextprotocol/server-github"],
        env: %{"GITHUB_TOKEN" => token}
      })

      # List active connections
      ClientSupervisor.list_connections()

      # Stop a connection
      ClientSupervisor.stop_connection("github")
  """

  use DynamicSupervisor

  alias Arbor.Gateway.MCP.ClientConnection

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  @doc """
  Start a supervised MCP client connection.

  ## Options

  - `:transport` — `:stdio`, `:http`, `:sse`, or `:beam` (required)
  - `:command` — command for stdio transport (string or list)
  - `:url` — URL for HTTP/SSE transport
  - `:env` — environment variables map for stdio transport
  - `:agent_id` — owning agent ID (for capability scoping)
  - `:auto_discover` — discover tools on connect (default: true)
  """
  @spec start_connection(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start_connection(server_name, config) when is_binary(server_name) and is_map(config) do
    child_spec = {ClientConnection, Map.put(config, :server_name, server_name)}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc "Stop a connection by server name."
  @spec stop_connection(String.t()) :: :ok | {:error, :not_found}
  def stop_connection(server_name) do
    case find_connection(server_name) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      :error ->
        {:error, :not_found}
    end
  end

  @doc "List all active connections as `{server_name, pid, status}` tuples."
  @spec list_connections() :: [{String.t(), pid(), atom()}]
  def list_connections do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, :worker, _} when is_pid(pid) ->
        try do
          case ClientConnection.status(pid) do
            {:ok, status} -> [{status.server_name, pid, status.connection_status}]
            _ -> []
          end
        catch
          :exit, _ -> []
        end

      _ ->
        []
    end)
  end

  @doc "Find a connection pid by server name."
  @spec find_connection(String.t()) :: {:ok, pid()} | :error
  def find_connection(server_name) do
    result =
      __MODULE__
      |> DynamicSupervisor.which_children()
      |> Enum.find_value(fn
        {_, pid, :worker, _} when is_pid(pid) ->
          try do
            case ClientConnection.server_name(pid) do
              ^server_name -> pid
              _ -> nil
            end
          catch
            :exit, _ -> nil
          end

        _ ->
          nil
      end)

    case result do
      nil -> :error
      pid -> {:ok, pid}
    end
  end
end
