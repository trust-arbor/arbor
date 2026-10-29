defmodule Arbor.Custody.SupervisedOwnerSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  @app :arbor_custody_supervised_owner_startup_probe
  @child_id :supervised_owner_startup_probe_child
  @child_name Arbor.Custody.SupervisedOwnerStartupProbeChild
  @impostor_name Arbor.Custody.SupervisedOwnerStartupProbeImpostor
  @detached_name Arbor.Custody.SupervisedOwnerDetachedProbe

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
           child: Arbor.Custody.supervised_registered_child_pid(app, [child_id], child_name),
           child_pid: Process.whereis(child_name),
           impostor:
             Arbor.Custody.supervised_registered_child_pid(app, [child_id], impostor_name),
           root: root,
           starting_root:
             Arbor.Custody.starting_application_root(app, Process.whereis(child_name), 1),
           wrong_depth:
             Arbor.Custody.starting_application_root(app, Process.whereis(child_name), 2),
           wrong_application:
             Arbor.Custody.starting_application_root(:kernel, Process.whereis(child_name), 1)
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
           description: ~c"Custody supervised-owner startup probe",
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
    assert during_start.starting_root == {:ok, during_start.root}
    assert during_start.wrong_depth == :error
    assert during_start.wrong_application == :error

    master = :application_controller.get_master(@app)
    assert is_pid(master) and Process.alive?(master)

    # After start the authoritative master lookup gives the same answer.
    assert {:ok, child} =
             Arbor.Custody.supervised_registered_child_pid(@app, [@child_id], @child_name)

    assert child == Process.whereis(@child_name)

    assert {:error, :not_supervised_owner} =
             Arbor.Custody.supervised_registered_child_pid(@app, [:not_the_child], @child_name)
  end

  test "security regression: claimed ancestry cannot promote an unrelated registered process" do
    assert :ok = Application.start(@app)
    assert_receive {:during_start, during_start}
    test_pid = self()

    {detached, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$ancestors", [during_start.root, during_start.child_pid])
        Process.put(:"$initial_call", {ProbeApplication, :start, 2})
        true = Process.register(self(), @detached_name)
        send(test_pid, {:detached_ready, self()})

        receive do
          :stop -> :ok
        end
      end)

    try do
      assert_receive {:detached_ready, ^detached}

      assert {:error, :not_supervised_owner} =
               Arbor.Custody.supervised_registered_child_pid(@app, [@child_id], @detached_name)

      assert :error = Arbor.Custody.starting_application_root(@app, detached, 1)

      assert {:ok, child} =
               Arbor.Custody.supervised_registered_child_pid(@app, [@child_id], @child_name)

      assert child == during_start.child_pid
    after
      send(detached, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^detached, :normal}
    end
  end

  test "starting_application_root/3 refuses processes outside a starting application" do
    assert :error = Arbor.Custody.starting_application_root(@app, self(), 1)
    assert :error = Arbor.Custody.starting_application_root(:no_such_application, self(), 1)
  end

  defp unload_probe_application do
    _ = Application.stop(@app)
    _ = :application.unload(@app)
    :ok
  end
end
