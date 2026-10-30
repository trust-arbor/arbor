defmodule Arbor.KernelRuntime.OAuthPackageAdoptionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  @modules [
    Arbor.Common.OAuth,
    Arbor.Common.OAuth.Config,
    Arbor.Common.OAuth.AuthCode,
    Arbor.Common.OAuth.AuthCode.Params,
    Arbor.Common.OAuth.DeviceCode,
    Arbor.Common.OAuth.DeviceCode.StartParams,
    Arbor.Common.OAuth.DeviceCode.PollParams,
    Arbor.Common.OAuth.DeviceCode.RefreshParams,
    Arbor.Common.OAuth.HttpClient,
    Arbor.Common.OAuth.HttpClient.Request,
    Arbor.Common.OAuth.HttpClient.Response,
    Arbor.Common.OAuth.HttpClient.Req,
    Arbor.Common.OAuth.HttpClient.Pool
  ]

  test "legacy OAuth module identities have a single package owner" do
    package_modules = Application.spec(:arbor_oauth, :modules) || []
    host_modules = Application.spec(:arbor_kernel_runtime, :modules) || []

    for module <- @modules do
      assert module in package_modules
      refute module in host_modules
      assert Application.get_application(module) == :arbor_oauth
    end
  end

  test "requiring the passive OAuth app does not implicitly admit HTTP providers or a pool owner" do
    assert :arbor_oauth in Application.spec(:arbor_kernel_runtime, :applications)
    assert Application.spec(:arbor_oauth, :mod) in [nil, []]
    assert Application.spec(:arbor_oauth, :registered) in [nil, []]

    applications = Application.spec(:arbor_oauth, :applications) || []

    for provider <- [:arbor_kernel_runtime, :arbor_security, :arbor_llm, :req, :finch, :mint] do
      refute provider in applications
    end
  end
end
