defmodule Arbor.Signals.ClusterRootBoundarySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-010"

  @moduletag :fast

  @tag spec: "KSEC-010"
  test "security regression: distribution peers are explicitly cluster root" do
    prior = Application.fetch_env(:arbor_kernel, :signals)
    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:cluster_trust_boundary, :zone_authorized)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:arbor_kernel, :signals, value)
        :error -> Application.delete_env(:arbor_kernel, :signals)
      end
    end)

    assert Arbor.Signals.cluster_trust_boundary() == :distribution_cookie_root
    assert Arbor.Signals.Config.cluster_trust_boundary() == :distribution_cookie_root
    refute Arbor.Common.NodeRegistry.security_boundary?()

    assert Mix.Tasks.Arbor.Rpc.remote_authority() == :root
    assert Mix.Tasks.Arbor.Phone.remote_authority() == :root
  end
end
