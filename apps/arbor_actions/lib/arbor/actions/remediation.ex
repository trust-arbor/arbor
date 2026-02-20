defmodule Arbor.Actions.Remediation do
  @moduledoc """
  BEAM runtime remediation actions.

  Provides Jido-compatible actions for fixing BEAM runtime issues.
  Each action requires specific capabilities for authorization.

  ## Actions

  | Action | Required Capability | Description |
  |--------|---------------------|-------------|
  | `KillProcess` | `:process_kill` | Terminate a process |
  | `StopSupervisor` | `:supervisor_control` | Stop a supervisor tree |
  | `RestartChild` | `:supervisor_control` | Restart a supervisor child |
  | `ForceGC` | `:process_gc` | Force garbage collection (auto-approved) |
  | `DrainQueue` | `:process_modify` | Drain messages from a queue |

  ## Safety

  All remediation actions are logged via signals for audit purposes.
  Actions verify capability authorization before execution.
  """

  require Logger
  alias Arbor.Actions

  defmodule KillProcess do
    @moduledoc """
    Terminate a process by PID.

    Requires `:process_kill` capability for authorization.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `pid` | string | yes | PID in string format |
    | `reason` | atom | no | Exit reason: :normal, :kill, :shutdown |

    ## Returns

    - `killed` - Boolean indicating if process was killed
    - `was_alive` - Whether process was alive before kill
    """

    use Jido.Action,
      name: "remediation_kill_process",
      description: "Terminate a process by PID",
      category: "remediation",
      tags: ["remediation", "process", "kill"],
      schema: [
        pid: [
          type: :string,
          required: true,
          doc: "PID in string format (e.g., '#PID<0.123.0>')"
        ],
        reason: [
          type: {:in, [:normal, :kill, :shutdown]},
          default: :shutdown,
          doc: "Exit reason"
        ]
      ]

    def taint_roles do
      %{pid: :control, reason: :control}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)

      case parse_pid(params.pid) do
        {:ok, pid} ->
          was_alive = Process.alive?(pid)
          reason = params[:reason] || :shutdown

          if was_alive do
            Process.exit(pid, reason)
            emit_remediation_signal(:kill_process, pid, %{reason: reason})
          end

          Actions.emit_completed(__MODULE__, %{
            killed: was_alive,
            was_alive: was_alive
          })

          {:ok, %{killed: was_alive, was_alive: was_alive}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp parse_pid(pid_string) when is_binary(pid_string) do
      # Try to parse PID from string like "#PID<0.123.0>" or "<0.123.0>"
      case Regex.run(~r/<(\d+)\.(\d+)\.(\d+)>/, pid_string) do
        [_, a, b, c] ->
          {:ok, :erlang.list_to_pid(~c"<#{a}.#{b}.#{c}>")}

        nil ->
          {:error, :invalid_pid_format}
      end
    end

    defp parse_pid(_), do: {:error, :invalid_pid_format}

    defp emit_remediation_signal(action, target, details) do
      Arbor.Signals.emit(:remediation, action, %{
        target: inspect(target),
        details: details,
        timestamp: DateTime.utc_now()
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defmodule StopSupervisor do
    @moduledoc """
    Stop a supervisor and all its children.

    Requires `:supervisor_control` capability for authorization.
    """

    use Jido.Action,
      name: "remediation_stop_supervisor",
      description: "Stop a supervisor and all its children",
      category: "remediation",
      tags: ["remediation", "supervisor", "stop"],
      schema: [
        pid: [
          type: :string,
          required: true,
          doc: "Supervisor PID in string format"
        ],
        reason: [
          type: {:in, [:normal, :shutdown]},
          default: :shutdown,
          doc: "Shutdown reason"
        ],
        timeout: [
          type: :non_neg_integer,
          default: 5_000,
          doc: "Shutdown timeout in milliseconds"
        ]
      ]

    def taint_roles do
      %{pid: :control, reason: :control, timeout: :data}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)

      case parse_pid(params.pid) do
        {:ok, pid} ->
          was_alive = Process.alive?(pid)
          reason = params[:reason] || :shutdown
          timeout = params[:timeout] || 5_000

          result =
            if was_alive do
              try do
                Supervisor.stop(pid, reason, timeout)
                emit_remediation_signal(:stop_supervisor, pid, %{reason: reason})
                :ok
              catch
                :exit, {:noproc, _} -> :not_supervisor
                :exit, {:timeout, _} -> :timeout
                :exit, reason -> {:exit, reason}
              end
            else
              :not_alive
            end

          Actions.emit_completed(__MODULE__, %{
            stopped: result == :ok,
            result: result
          })

          {:ok, %{stopped: result == :ok, result: result}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp parse_pid(pid_string) when is_binary(pid_string) do
      case Regex.run(~r/<(\d+)\.(\d+)\.(\d+)>/, pid_string) do
        [_, a, b, c] ->
          {:ok, :erlang.list_to_pid(~c"<#{a}.#{b}.#{c}>")}

        nil ->
          {:error, :invalid_pid_format}
      end
    end

    defp parse_pid(_), do: {:error, :invalid_pid_format}

    defp emit_remediation_signal(action, target, details) do
      Arbor.Signals.emit(:remediation, action, %{
        target: inspect(target),
        details: details,
        timestamp: DateTime.utc_now()
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defmodule RestartChild do
    @moduledoc """
    Restart a specific child of a supervisor.

    Requires `:supervisor_control` capability for authorization.
    """

    use Jido.Action,
      name: "remediation_restart_child",
      description: "Restart a specific child of a supervisor",
      category: "remediation",
      tags: ["remediation", "supervisor", "restart"],
      schema: [
        supervisor_pid: [
          type: :string,
          required: true,
          doc: "Supervisor PID in string format"
        ],
        child_id: [
          type: :any,
          required: true,
          doc: "Child ID to restart"
        ]
      ]

    def taint_roles do
      %{supervisor_pid: :control, child_id: :control}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, sup_pid} <- parse_pid(params.supervisor_pid),
           :ok <- Supervisor.terminate_child(sup_pid, params.child_id),
           {:ok, _} <- Supervisor.restart_child(sup_pid, params.child_id) do
        emit_remediation_signal(:restart_child, sup_pid, %{child_id: params.child_id})

        Actions.emit_completed(__MODULE__, %{restarted: true})
        {:ok, %{restarted: true}}
      else
        {:error, :not_found} ->
          {:ok, %{restarted: false, reason: :child_not_found}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp parse_pid(pid_string) when is_binary(pid_string) do
      case Regex.run(~r/<(\d+)\.(\d+)\.(\d+)>/, pid_string) do
        [_, a, b, c] ->
          {:ok, :erlang.list_to_pid(~c"<#{a}.#{b}.#{c}>")}

        nil ->
          {:error, :invalid_pid_format}
      end
    end

    defp parse_pid(_), do: {:error, :invalid_pid_format}

    defp emit_remediation_signal(action, target, details) do
      Arbor.Signals.emit(:remediation, action, %{
        target: inspect(target),
        details: details,
        timestamp: DateTime.utc_now()
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defmodule ForceGC do
    @moduledoc """
    Force garbage collection on a process.

    This is a safe operation that is auto-approved.
    Requires `:process_gc` capability.
    """

    use Jido.Action,
      name: "remediation_force_gc",
      description: "Force garbage collection on a process",
      category: "remediation",
      tags: ["remediation", "process", "gc", "safe"],
      schema: [
        pid: [
          type: :string,
          required: true,
          doc: "PID in string format"
        ]
      ]

    def taint_roles do
      %{pid: :control}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)

      case parse_pid(params.pid) do
        {:ok, pid} ->
          if Process.alive?(pid) do
            :erlang.garbage_collect(pid)
            emit_remediation_signal(:force_gc, pid, %{})

            {:memory, memory_after} = Process.info(pid, :memory)

            Actions.emit_completed(__MODULE__, %{
              collected: true,
              memory_after: memory_after
            })

            {:ok, %{collected: true, memory_after: memory_after}}
          else
            {:ok, %{collected: false, reason: :not_alive}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp parse_pid(pid_string) when is_binary(pid_string) do
      case Regex.run(~r/<(\d+)\.(\d+)\.(\d+)>/, pid_string) do
        [_, a, b, c] ->
          {:ok, :erlang.list_to_pid(~c"<#{a}.#{b}.#{c}>")}

        nil ->
          {:error, :invalid_pid_format}
      end
    end

    defp parse_pid(_), do: {:error, :invalid_pid_format}

    defp emit_remediation_signal(action, target, details) do
      Arbor.Signals.emit(:remediation, action, %{
        target: inspect(target),
        details: details,
        timestamp: DateTime.utc_now()
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defmodule DrainQueue do
    @moduledoc """
    Drain messages from a process's message queue.

    This is a potentially dangerous operation that modifies process state.
    Requires `:process_modify` capability.

    Note: This action cannot directly drain another process's queue in Elixir.
    Instead, it suggests killing the process as the remediation.
    For actual queue draining, the process itself must cooperate.
    """

    use Jido.Action,
      name: "remediation_drain_queue",
      description:
        "Suggest draining messages from a process queue (requires cooperation or kill)",
      category: "remediation",
      tags: ["remediation", "process", "queue", "drain"],
      schema: [
        pid: [
          type: :string,
          required: true,
          doc: "PID in string format"
        ],
        batch_size: [
          type: :non_neg_integer,
          default: 1_000,
          doc: "Messages per batch"
        ],
        max_messages: [
          type: :non_neg_integer,
          default: 10_000,
          doc: "Maximum messages to drain"
        ]
      ]

    def taint_roles do
      %{pid: :control, batch_size: :data, max_messages: :data}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)

      case parse_pid(params.pid) do
        {:ok, pid} ->
          if Process.alive?(pid) do
            {:message_queue_len, queue_len} = Process.info(pid, :message_queue_len)

            # We cannot directly drain another process's queue in Elixir
            # Return info about the queue and suggest remediation
            emit_remediation_signal(:drain_queue_attempted, pid, %{
              queue_len: queue_len,
              suggestion: :kill_process_if_unresponsive
            })

            Actions.emit_completed(__MODULE__, %{
              inspected: true,
              queue_len: queue_len,
              suggestion:
                "Cannot drain external process queue. Consider killing the process if unresponsive."
            })

            {:ok,
             %{
               inspected: true,
               queue_len: queue_len,
               can_drain: false,
               suggestion: :kill_process
             }}
          else
            {:ok, %{inspected: false, reason: :not_alive}}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp parse_pid(pid_string) when is_binary(pid_string) do
      case Regex.run(~r/<(\d+)\.(\d+)\.(\d+)>/, pid_string) do
        [_, a, b, c] ->
          {:ok, :erlang.list_to_pid(~c"<#{a}.#{b}.#{c}>")}

        nil ->
          {:error, :invalid_pid_format}
      end
    end

    defp parse_pid(_), do: {:error, :invalid_pid_format}

    defp emit_remediation_signal(action, target, details) do
      Arbor.Signals.emit(:remediation, action, %{
        target: inspect(target),
        details: details,
        timestamp: DateTime.utc_now()
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
