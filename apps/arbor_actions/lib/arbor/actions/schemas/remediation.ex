defmodule Arbor.Actions.Schemas.Remediation do
  @moduledoc """
  Schema definitions for remediation actions.

  These schemas define the parameters for BEAM runtime remediation operations.
  Each operation requires specific capabilities for authorization.
  """

  @doc """
  Schema for killing a process.

  Requires `:process_kill` capability.
  """
  def kill_process do
    %{
      name: "kill_process",
      description: "Terminate a process by PID. Requires :process_kill capability.",
      schema: %{
        type: "object",
        properties: %{
          pid: %{type: "string", description: "PID in string format (e.g., '#PID<0.123.0>')"},
          reason: %{
            type: "string",
            description: "Exit reason (normal, kill, shutdown)",
            enum: ["normal", "kill", "shutdown"],
            default: "shutdown"
          }
        },
        required: ["pid"]
      }
    }
  end

  @doc """
  Schema for stopping a supervisor.

  Requires `:supervisor_control` capability.
  """
  def stop_supervisor do
    %{
      name: "stop_supervisor",
      description:
        "Stop a supervisor and all its children. Requires :supervisor_control capability.",
      schema: %{
        type: "object",
        properties: %{
          pid: %{type: "string", description: "Supervisor PID in string format"},
          reason: %{
            type: "string",
            description: "Shutdown reason",
            enum: ["normal", "shutdown"],
            default: "shutdown"
          },
          timeout: %{
            type: "integer",
            description: "Shutdown timeout in milliseconds",
            default: 5000
          }
        },
        required: ["pid"]
      }
    }
  end

  @doc """
  Schema for restarting a supervisor child.

  Requires `:supervisor_control` capability.
  """
  def restart_child do
    %{
      name: "restart_child",
      description:
        "Restart a specific child of a supervisor. Requires :supervisor_control capability.",
      schema: %{
        type: "object",
        properties: %{
          supervisor_pid: %{type: "string", description: "Supervisor PID in string format"},
          child_id: %{type: "string", description: "Child ID to restart"}
        },
        required: ["supervisor_pid", "child_id"]
      }
    }
  end

  @doc """
  Schema for forcing garbage collection.

  Requires `:process_gc` capability (auto-approved as safe operation).
  """
  def force_gc do
    %{
      name: "force_gc",
      description: "Force garbage collection on a process. Safe, auto-approved operation.",
      schema: %{
        type: "object",
        properties: %{
          pid: %{type: "string", description: "PID in string format"}
        },
        required: ["pid"]
      }
    }
  end

  @doc """
  Schema for draining a message queue.

  Requires `:process_modify` capability.
  """
  def drain_queue do
    %{
      name: "drain_queue",
      description: "Drain messages from a process queue. Requires :process_modify capability.",
      schema: %{
        type: "object",
        properties: %{
          pid: %{type: "string", description: "PID in string format"},
          batch_size: %{
            type: "integer",
            description: "Number of messages to drain per batch",
            default: 1000
          },
          max_messages: %{
            type: "integer",
            description: "Maximum total messages to drain",
            default: 10000
          }
        },
        required: ["pid"]
      }
    }
  end

  @doc """
  Returns all remediation action schemas.
  """
  def all do
    [
      kill_process(),
      stop_supervisor(),
      restart_child(),
      force_gc(),
      drain_queue()
    ]
  end
end
