defmodule Arbor.Trust.ApplicationSpecSecurityRegressionTest do
  @moduledoc """
  Security regression: generated OTP spec omits persistence/pubsub providers, and
  a fresh peer :activation_only start neither starts nor loads them.
  """
  use ExUnit.Case, async: false

  alias Arbor.KernelRuntime.ApplicationSpecPeer

  @omitted [:arbor_persistence, :phoenix_pubsub, :ecto, :ecto_sql, :postgrex]
  @required MapSet.new([
              :arbor_kernel_runtime,
              :arbor_security,
              :elixir,
              :jason,
              :kernel,
              :logger,
              :stdlib,
              :telemetry
            ])

  @tag :fast
  test "security regression: consulted .app required set omits persistence and pubsub" do
    props = ApplicationSpecPeer.consult_env_app!(:arbor_trust, Mix.Project.build_path())
    required = MapSet.new(Keyword.get(props, :applications, []))
    optional = Keyword.get(props, :optional_applications, [])
    included = Keyword.get(props, :included_applications, [])

    assert required == @required
    assert optional == []
    assert included == []

    Enum.each(@omitted, fn app ->
      refute app in required
      refute app in optional
      refute app in included
    end)
  end

  @tag :slow
  @tag :integration
  @tag :security_regression
  test "security regression: activation_only peer does not start or load provider apps" do
    control = ApplicationSpecPeer.start!()

    try do
      :ok =
        ApplicationSpecPeer.prepare_restricted!(
          control,
          :arbor_trust,
          [:arbor_kernel, :arbor_security, :arbor_trust],
          Mix.Project.build_path()
        )

      :ok =
        ApplicationSpecPeer.assert_omitted_ebins(
          control,
          @omitted,
          Mix.Project.build_path()
        )

      :ok = ApplicationSpecPeer.put_activation_profile(control, start_profile: :activation_only)

      assert {:ok, _} =
               ApplicationSpecPeer.call(
                 control,
                 Application,
                 :ensure_all_started,
                 [:arbor_trust]
               )

      :ok =
        ApplicationSpecPeer.assert_omitted_ebins(
          control,
          @omitted,
          Mix.Project.build_path()
        )

      started = ApplicationSpecPeer.started_applications(control)
      loaded = ApplicationSpecPeer.loaded_applications(control)

      Enum.each(@omitted, fn app ->
        refute app in started
        refute app in loaded
      end)

      refute ApplicationSpecPeer.call(control, :erlang, :module_loaded, [Phoenix.PubSub])
      refute ApplicationSpecPeer.call(control, :erlang, :module_loaded, [Ecto])
      refute ApplicationSpecPeer.call(control, :erlang, :module_loaded, [Arbor.Persistence])

      assert ApplicationSpecPeer.call(
               control,
               Process,
               :whereis,
               [Arbor.Trust.ProviderGate]
             ) == nil

      assert ApplicationSpecPeer.call(control, Process, :whereis, [Arbor.Trust.Supervisor]) == nil
      assert ApplicationSpecPeer.call(control, Process, :whereis, [Arbor.Trust.Manager]) == nil
    after
      ApplicationSpecPeer.stop(control)
    end
  end
end
