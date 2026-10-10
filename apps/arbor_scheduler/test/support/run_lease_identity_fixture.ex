defmodule Arbor.Scheduler.RunLeaseIdentityFixture do
  @moduledoc false

  alias Arbor.Scheduler.Identity
  alias Arbor.Security

  def ensure_started! do
    Code.ensure_loaded!(Identity)

    if function_exported?(Identity, :register_run_identity, 2) do
      :ok = ensure_security_tree!()

      case Process.whereis(Identity) do
        pid when is_pid(pid) -> ensure_ready!(pid)
        nil -> bootstrap_identity!()
      end

      ensure_run_lease_supervisor!()
    else
      :ok
    end
  end

  defp ensure_run_lease_supervisor! do
    case Process.whereis(Arbor.Scheduler.RunLeaseSupervisor) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        token = Application.fetch_env!(:arbor_scheduler, :test_scheduler_mutation_token)

        case Supervisor.start_child(
               Arbor.Scheduler.Supervisor,
               {Arbor.Scheduler.RunLeaseSupervisor, scheduler_mutation_token: token}
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start run lease supervisor: #{inspect(reason)}"
        end
    end
  end

  defp bootstrap_identity! do
    case start_identity() do
      {:ok, pid} -> ensure_ready!(pid)
      {:error, {:already_started, pid}} -> ensure_ready!(pid)
      {:error, reason} -> raise "failed to bootstrap scheduler identity: #{inspect(reason)}"
    end
  end

  # A fresh scheduler identity stays dormant (alive, no authority) until an
  # operator grants its required capabilities; the fixture plays operator.
  defp ensure_ready!(pid) do
    case await_ready(pid) do
      :ok ->
        :ok

      {:error, :not_ready} ->
        if Process.alive?(pid), do: provision_and_retry!(), else: bootstrap_identity!()
    end
  end

  defp provision_and_retry! do
    {:ok, agent_ids} = Security.lookup_identity_ids_by_display_name("scheduler")

    Enum.each(agent_ids, fn agent_id ->
      Enum.each(Identity.required_capability_uris(), fn resource ->
        case Security.grant_fixture(principal: agent_id, resource: resource) do
          {:ok, _capability} ->
            :ok

          {:error, reason} ->
            raise "failed to grant scheduler fixture cap: #{inspect(reason)}"
        end
      end)
    end)

    case Identity.retry_bootstrap() do
      :ok -> :ok
      {:error, reason} -> raise "scheduler identity did not become ready: #{inspect(reason)}"
    end
  end

  defp await_ready(pid) do
    if Process.alive?(pid) do
      case Identity.await_ready() do
        :ok -> :ok
        {:error, _reason} -> {:error, :not_ready}
      end
    else
      {:error, :not_ready}
    end
  end

  defp ensure_security_tree! do
    case Security.restore_runtime_fixture() do
      :ok ->
        probe = "agent_" <> String.duplicate("0", 64)

        case Security.signing_key_status(probe) do
          {:error, :no_signing_key} -> :ok
          {:ok, :available} -> :ok
          other -> raise "signing key store unavailable: #{inspect(other)}"
        end

      other ->
        raise "security test tree unavailable: #{inspect(other)}"
    end
  end

  defp start_identity do
    token = Application.fetch_env!(:arbor_scheduler, :test_scheduler_mutation_token)
    spec = Supervisor.child_spec({Identity, scheduler_mutation_token: token}, restart: :temporary)
    Supervisor.start_child(Arbor.Scheduler.Supervisor, spec)
  end
end
