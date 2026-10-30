defmodule Arbor.Security.OIDCPackageAdoptionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @package_modules [
    Arbor.Capabilities.OIDC,
    Arbor.Capabilities.OIDC.AuthCodeFlow,
    Arbor.Capabilities.OIDC.DeviceFlow,
    Arbor.Capabilities.OIDC.Discovery,
    Arbor.Capabilities.OIDC.TokenVerifier,
    Arbor.Capabilities.OIDC.Verification
  ]

  @host_wrappers [
    Arbor.Security.OIDC.AuthCodeFlow,
    Arbor.Security.OIDC.DeviceFlow,
    Arbor.Security.OIDC.Discovery,
    Arbor.Security.OIDC.TokenVerifier
  ]

  setup_all do
    case Application.load(:arbor_capabilities_oidc) do
      :ok -> :ok
      {:error, {:already_loaded, :arbor_capabilities_oidc}} -> :ok
    end
  end

  test "protocol modules have one package owner and compatibility wrappers stay host-owned" do
    package_modules = Application.spec(:arbor_capabilities_oidc, :modules) || []
    host_modules = Application.spec(:arbor_security, :modules) || []
    assert MapSet.disjoint?(MapSet.new(package_modules), MapSet.new(host_modules))

    for module <- @package_modules do
      assert module in package_modules
      refute module in host_modules
      assert Application.get_application(module) == :arbor_capabilities_oidc
    end

    for module <- @host_wrappers do
      assert module in host_modules
      refute module in package_modules
      assert Application.get_application(module) == :arbor_security
    end
  end

  test "the optional protocol app is passive and does not implicitly admit providers or host apps" do
    assert Application.spec(:arbor_capabilities_oidc, :mod) in [nil, []]
    assert Application.spec(:arbor_capabilities_oidc, :registered) in [nil, []]

    applications = Application.spec(:arbor_capabilities_oidc, :applications) || []
    assert :arbor_oauth in applications

    for app <- [
          :arbor_security,
          :arbor_kernel,
          :arbor_kernel_runtime,
          :arbor_custody,
          :joken,
          :joken_jwks,
          :jose,
          :plug_crypto,
          :req,
          :finch,
          :mint
        ] do
      refute app in applications
    end

    for key <- [:applications, :optional_applications, :included_applications] do
      refute :arbor_capabilities_oidc in (Application.spec(:arbor_security, key) || [])
    end
  end
end
