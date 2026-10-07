defmodule Arbor.Security.SupervisedCallDispatchSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "SSEC-004"

  @moduletag :fast
  @moduletag security: :regression

  @services [
    {Arbor.Security.CapabilityStore, :capability_mutation_unauthorized},
    {Arbor.Security.Identity.NonceCache, :unsupported_request},
    {Arbor.Security.UriRegistry, :unsupported_request}
  ]

  setup_all do
    case Supervisor.start_child(
           Arbor.Security.Supervisor,
           {Arbor.Security.UriRegistry, []}
         ) do
      {:ok, _pid} ->
        on_exit(&stop_uri_registry_child/0)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, :already_present} ->
        :ok = Supervisor.delete_child(Arbor.Security.Supervisor, Arbor.Security.UriRegistry)

        {:ok, _pid} =
          Supervisor.start_child(Arbor.Security.Supervisor, {Arbor.Security.UriRegistry, []})

        on_exit(&stop_uri_registry_child/0)
        :ok
    end
  end

  for {service, denial} <- @services do
    @tag spec: "SSEC-004"
    test "security regression: #{inspect(service)} rejects unknown calls without crashing" do
      service = unquote(service)
      denial = unquote(denial)
      pid = Process.whereis(service)

      assert is_pid(pid)
      assert supervised_child_pid(Arbor.Security.Supervisor, service) == pid

      assert {:error, ^denial} =
               GenServer.call(pid, {:security_regression_unknown_call, :opaque})

      assert Process.alive?(pid)
      assert Process.whereis(service) == pid
    end
  end

  defp supervised_child_pid(supervisor, child_id) do
    Enum.find_value(Supervisor.which_children(supervisor), fn
      {^child_id, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp stop_uri_registry_child do
    case Supervisor.terminate_child(
           Arbor.Security.Supervisor,
           Arbor.Security.UriRegistry
         ) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(Arbor.Security.Supervisor, Arbor.Security.UriRegistry) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
