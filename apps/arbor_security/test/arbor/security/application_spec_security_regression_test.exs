defmodule Arbor.Security.ApplicationSpecSecurityRegressionTest do
  @moduledoc """
  Security regression: generated OTP spec omits JWT/HTTP providers, and a
  fresh peer :activation_only start neither starts nor loads them.
  """
  use ExUnit.Case, async: false

  alias Arbor.KernelRuntime.ApplicationSpecPeer

  @omitted [:joken, :joken_jwks, :req, :jose, :finch, :mint]
  @required MapSet.new([
              :arbor_kernel_runtime,
              :elixir,
              :jason,
              :kernel,
              :logger,
              :plug_crypto,
              :stdlib,
              :telemetry
            ])
  @named_stores [
    :arbor_security_capabilities,
    :arbor_security_identities,
    :arbor_security_signing_keys,
    :arbor_security_issuers
  ]

  @tag :fast
  test "security regression: consulted .app required set omits JWT and HTTP providers" do
    props =
      ApplicationSpecPeer.consult_env_app!(:arbor_security, Mix.Project.build_path())

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
          :arbor_security,
          [:arbor_kernel, :arbor_security],
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
                 [:arbor_security]
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

      refute ApplicationSpecPeer.call(control, :erlang, :module_loaded, [Joken])
      refute ApplicationSpecPeer.call(control, :erlang, :module_loaded, [Req])
      refute ApplicationSpecPeer.call(control, :erlang, :module_loaded, [Finch])
      refute ApplicationSpecPeer.call(control, :erlang, :module_loaded, [Mint])

      assert ApplicationSpecPeer.call(
               control,
               Process,
               :whereis,
               [Arbor.Security.ProviderGate]
             ) == nil

      Enum.each(@named_stores, fn name ->
        assert ApplicationSpecPeer.call(control, Process, :whereis, [name]) == nil
      end)
    after
      ApplicationSpecPeer.stop(control)
    end
  end
end
