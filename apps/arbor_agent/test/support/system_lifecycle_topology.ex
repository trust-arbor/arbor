defmodule Arbor.Agent.Test.SystemLifecycleTopology do
  @moduledoc """
  Test-only helpers for the system lifecycle principal (decision D4).

  The principal (`Arbor.Agent.SystemLifecycleAuthority`) admits a caller only
  when it is the exact supervised, registered `Arbor.Agent.Bootstrap` or
  `Arbor.Agent.Reconciler` child of the `:arbor_agent` application root
  (`Arbor.Agent.AppSupervisor`) presenting the shared startup token. Test config
  leaves that supervisor empty (`start_children: false`), so these helpers add
  the production children under it, exactly as `Arbor.Agent.Application` would,
  and remove them afterwards. Nothing here widens the production admission.
  """

  alias Arbor.Agent.{Bootstrap, Reconciler, SystemLifecycleAuthority}

  @app_supervisor Arbor.Agent.AppSupervisor

  @doc """
  Start the principal under the application root with a fresh token and wait
  until it is ready. Returns `%{token:, principal_id:}`.
  """
  @spec start_owner!() :: %{token: reference(), principal_id: String.t()}
  def start_owner! do
    token = make_ref()
    stop_child(SystemLifecycleAuthority)
    start_child!({SystemLifecycleAuthority, system_lifecycle_token: token})
    :ok = SystemLifecycleAuthority.await_ready(30_000)
    {:ok, principal_id} = SystemLifecycleAuthority.principal_id()
    %{token: token, principal_id: principal_id}
  end

  @doc "Start the production-named Reconciler (timer disabled) under the application root."
  @spec start_reconciler!(reference(), keyword()) :: pid()
  def start_reconciler!(token, start_opts) do
    stop_child(Reconciler)

    start_child!(
      {Reconciler,
       enabled: false, g1_policy: :start, system_lifecycle_token: token, start_opts: start_opts}
    )
  end

  @doc "Start the production-named Bootstrap under the application root."
  @spec start_bootstrap!(reference(), keyword()) :: pid()
  def start_bootstrap!(token, start_opts) do
    stop_child(Bootstrap)

    start_child!(
      {Bootstrap, boot_delay: 0, system_lifecycle_token: token, start_opts: start_opts}
    )
  end

  @doc "Terminate and remove a child of the application root, if present."
  @spec stop_child(module()) :: :ok
  def stop_child(id) do
    _ = Supervisor.terminate_child(@app_supervisor, id)
    _ = Supervisor.delete_child(@app_supervisor, id)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp start_child!(spec) do
    case Supervisor.start_child(@app_supervisor, spec) do
      {:ok, pid} -> pid
      other -> raise "SystemLifecycleTopology could not start #{inspect(spec)}: #{inspect(other)}"
    end
  end
end
