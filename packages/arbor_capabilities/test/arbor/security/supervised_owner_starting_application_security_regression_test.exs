defmodule Arbor.Security.SupervisedOwnerStartingApplicationSecurityRegressionTest do
  @moduledoc """
  Security regression (2026-10-09): an exact-supervision authorization lookup
  must never kill the application it is asked about.

  `SupervisedOwner.application_root/1` used to call
  `:application_master.get_child/1` unconditionally. While an application's
  `start/2` callback is still running, OTP 28's application master has no
  child yet and crashes with `badarg` on that request. The application
  controller then never receives `application_started`, so
  `Application.ensure_all_started/1` hangs forever with the application stuck
  in `starting`. In the dev daemon this happened to `:arbor_trust` on every
  boot: `Trust.CapabilityGrantOwner` claimed signing-key custody from its
  continuation during Trust startup, the key store's role admission called
  `SupervisedOwner.authorized?/3` for `:arbor_trust`, and the boot stalled at
  15/26 applications.

  During `start/2` the exact supervised child must still be admitted (role
  owners such as `Scheduler.Identity` are awaited by their own `start/2`),
  everything else must be refused, and the application master must survive.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Security.SupervisedOwner

  @app :arbor_security_supervised_owner_startup_probe
  @child_id :supervised_owner_startup_probe_child

  defmodule ProbeApplication do
    @moduledoc false
    use Application

    alias Arbor.Security.SupervisedOwner

    @impl true
    def start(_type, {app, child_id, test_pid}) do
      {:ok, root} =
        Supervisor.start_link(
          [%{id: child_id, start: {Agent, :start_link, [fn -> :probe end]}}],
          strategy: :one_for_one
        )

      [{^child_id, child, _type, _modules}] = Supervisor.which_children(root)

      # A process the exact child spawned sits one level too deep.
      grandchild = Agent.get(child, fn _state -> spawn(fn -> Process.sleep(:infinity) end) end)

      # Asked from inside start/2, exactly like a role owner claiming custody
      # while its own application is still starting.
      send(
        test_pid,
        {:during_start,
         %{
           root: SupervisedOwner.application_root(app),
           child: SupervisedOwner.authorized?(child, app, [child_id]),
           starter: SupervisedOwner.authorized?(self(), app, [child_id]),
           grandchild: SupervisedOwner.authorized?(grandchild, app, [child_id]),
           outsider: SupervisedOwner.authorized?(test_pid, app, [child_id])
         }}
      )

      Process.exit(grandchild, :kill)
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
           description: ~c"SupervisedOwner startup probe",
           vsn: ~c"0.0.1",
           modules: [ProbeApplication],
           registered: [],
           applications: [:kernel, :stdlib],
           mod: {ProbeApplication, {@app, @child_id, self()}}
         ]}
      )

    :ok
  end

  test "security regression: SupervisedOwner checks during start/2 never kill the application master" do
    starter = Task.async(fn -> Application.start(@app) end)

    # Before the fix the master died with badarg and this never returned.
    assert {:ok, :ok} = Task.yield(starter, 10_000) || Task.shutdown(starter, :brutal_kill)

    master = :application_controller.get_master(@app)
    assert is_pid(master)
    assert Process.alive?(master)
    assert Enum.any?(Application.started_applications(), &match?({@app, _, _}, &1))
  end

  test "security regression: only the exact supervised child is admitted while start/2 runs" do
    starter = Task.async(fn -> Application.start(@app) end)
    assert {:ok, :ok} = Task.yield(starter, 10_000) || Task.shutdown(starter, :brutal_kill)

    assert_received {:during_start, during_start}
    assert during_start.root == {:error, :application_unavailable}
    assert during_start.child == true
    assert during_start.starter == false
    assert during_start.grandchild == false
    assert during_start.outsider == false

    # Once the application controller marks it started, the exact supervised
    # child is admitted through the authoritative master lookup.
    assert {:ok, root} = SupervisedOwner.application_root(@app)
    [{@child_id, child, _type, _modules}] = Supervisor.which_children(root)
    assert SupervisedOwner.authorized?(child, @app, [@child_id])
    refute SupervisedOwner.authorized?(self(), @app, [@child_id])
  end

  defp unload_probe_application do
    _ = Application.stop(@app)
    _ = :application.unload(@app)
    :ok
  end
end
