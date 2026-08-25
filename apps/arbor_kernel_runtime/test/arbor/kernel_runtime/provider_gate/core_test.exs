defmodule Arbor.KernelRuntime.ProviderGate.CoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.KernelRuntime.ProviderGate.Core

  test "full plans the closed network and monitor roots" do
    assert {:ok, [:os_mon, :recon, :mint, :finch, :req]} = Core.plan(:full)
    assert Core.roots() == [:os_mon, :recon, :mint, :finch, :req]
  end

  test "activation_only plans no roots" do
    assert {:ok, []} = Core.plan(:activation_only)
  end

  test "unknown profiles fail closed" do
    assert {:error, {:invalid_start_profile, :unknown}} = Core.plan(:unknown)
  end
end
