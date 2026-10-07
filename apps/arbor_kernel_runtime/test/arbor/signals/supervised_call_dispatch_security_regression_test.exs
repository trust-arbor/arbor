defmodule Arbor.Signals.SupervisedCallDispatchSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-009"

  @moduletag :fast
  @moduletag security: :regression

  @services [Arbor.Signals.Store, Arbor.Signals.TopicKeys]

  setup do
    Arbor.Signals.TestCase.ensure_processes()
    :ok
  end

  for service <- @services do
    @tag spec: "KSEC-009"
    test "security regression: #{inspect(service)} rejects unknown calls without crashing" do
      service = unquote(service)
      pid = Process.whereis(service)

      assert is_pid(pid)
      assert supervised_child_pid(Arbor.Signals.Supervisor, service) == pid

      assert {:error, :unsupported_request} =
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
end
