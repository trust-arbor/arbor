defmodule Arbor.Security.ProviderGate.CoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Security.ProviderGate.Core

  test "full plans the closed JWT and HTTP roots" do
    assert {:ok, [:joken, :joken_jwks, :req]} = Core.plan(:full)
  end

  test "activation_only plans no roots" do
    assert {:ok, []} = Core.plan(:activation_only)
  end

  test "unknown profiles fail closed" do
    assert {:error, {:invalid_start_profile, "full"}} = Core.plan("full")
  end
end
