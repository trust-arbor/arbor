defmodule Arbor.Common.SupervisedOwnerStartingApplicationTest do
  @moduledoc """
  Regression (2026-10-10): supervised-owner lookups must work while the owning
  application is still inside `start/2`, without asking its master.

  `Arbor.Common.supervised_registered_child_pid/4` failed closed until the
  application controller reported the application started (asking the master
  earlier crashes it on OTP 28). The scheduler's run-lease recovery resolves
  its store through this lookup, and `Scheduler.Application.start/2` waits for
  that recovery, so `:arbor_scheduler` deadlocked on its own start: the
  reaper gave up with `:recovery_in_progress` and every boot failed.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  @app :arbor_common_supervised_owner_startup_probe
  @child_id :supervised_owner_startup_probe_child
  @child_name Arbor.Common.SupervisedOwnerStartupProbeChild
  @impostor_name Arbor.Common.SupervisedOwnerStartupProbeImpostor

  defmodule ProbeApplication do
    @moduledoc false
    use Application

    @impl true
    def start(_type, {app, child_id, child_name, impostor_name, test_pid}) do
      {:ok, root} =
        Supervisor.start_link(
          [
            %{
              id: child_id,
              start: {Agent, :start_link, [fn -> :probe end, [name: child_name]]}
            }
          ],
          strategy: :one_for_one
        )

      # Holds a registered name but sits one level below the exact child.
      impostor = Agent.get(child_name, fn _state -> spawn(fn -> Process.sleep(:infinity) end) end)
      true = Process.register(impostor, impostor_name)

      send(
        test_pid,
        {:during_start,
         %{
           child: Arbor.Common.supervised_registered_child_pid(app, [child_id], child_name),
           child_pid: Process.whereis(child_name),
           impostor: Arbor.Common.supervised_registered_child_pid(app, [child_id], impostor_name)
         }}
      )

      Process.exit(impostor, :kill)
      {:ok, root}
    end
  end

  setup do
    on_exit(&unload_probe_application/0)
    unload_probe_application()

    :ok =
      :application.load(
        {:application, @app,
         [
           description: ~c"Common.SupervisedOwner startup probe",
           vsn: ~c"0.0.1",
           modules: [ProbeApplication],
           registered: [],
           applications: [:kernel, :stdlib],
           mod: {ProbeApplication, {@app, @child_id, @child_name, @impostor_name, self()}}
         ]}
      )

    :ok
  end

  test "security regression: an application's own exact child resolves while its start/2 runs" do
    starter = Task.async(fn -> Application.start(@app) end)
    assert {:ok, :ok} = Task.yield(starter, 10_000) || Task.shutdown(starter, :brutal_kill)

    assert_received {:during_start, during_start}
    assert during_start.child == {:ok, during_start.child_pid}
    assert during_start.impostor == {:error, :not_supervised_owner}

    master = :application_controller.get_master(@app)
    assert is_pid(master) and Process.alive?(master)

    # After start the authoritative master lookup gives the same answer.
    assert {:ok, child} =
             Arbor.Common.supervised_registered_child_pid(@app, [@child_id], @child_name)

    assert child == Process.whereis(@child_name)
  end

  test "starting_application_root/3 refuses processes outside a starting application" do
    assert :error = Arbor.Common.starting_application_root(@app, self(), 1)
    assert :error = Arbor.Common.starting_application_root(:no_such_application, self(), 1)
  end

  defp unload_probe_application do
    _ = Application.stop(@app)
    _ = :application.unload(@app)
    :ok
  end
end
