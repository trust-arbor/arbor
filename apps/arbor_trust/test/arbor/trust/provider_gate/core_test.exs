defmodule Arbor.Trust.ProviderGate.CoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Trust.ProviderGate.Core

  test "full plans persistence and pubsub roots" do
    assert {:ok, [:arbor_persistence, :phoenix_pubsub]} = Core.plan(:full)
  end

  test "activation_only plans no roots" do
    assert {:ok, []} = Core.plan(:activation_only)
  end

  test "unknown profiles fail closed" do
    assert {:error, {:invalid_start_profile, nil}} = Core.plan(nil)
  end
end
