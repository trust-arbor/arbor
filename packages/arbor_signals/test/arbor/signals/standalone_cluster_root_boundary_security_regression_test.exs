defmodule Arbor.Signals.StandaloneClusterRootBoundarySecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  test "security regression: standalone distribution peers remain explicit cluster root" do
    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:cluster_trust_boundary, :zone_authorized)

    assert Arbor.Signals.cluster_trust_boundary() == :distribution_cookie_root
    assert Arbor.Signals.Config.cluster_trust_boundary() == :distribution_cookie_root
  end
end
