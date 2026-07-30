defmodule Arbor.AI.RouteConcurrencyCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.AI.RouteConcurrencyCore

  describe "new/1 and normalize_limits/1" do
    test "accepts empty map" do
      assert {:ok, state} = RouteConcurrencyCore.new(%{})
      assert state.limits == %{}
      assert RouteConcurrencyCore.snapshot(state) == %{}
    end

    test "normalizes atom and string keys without creating atoms" do
      assert {:ok, state} =
               RouteConcurrencyCore.new(%{
                 :openai => %{arbor: 2},
                 "anthropic" => %{"acp" => 3}
               })

      assert state.limits[{"openai", "arbor"}] == 2
      assert state.limits[{"anthropic", "acp"}] == 3
    end

    test "rejects duplicate canonical keys from atom/string collision" do
      assert {:error, :malformed_config} =
               RouteConcurrencyCore.new(%{
                 :openai => %{arbor: 1},
                 "openai" => %{"arbor" => 2}
               })
    end

    test "rejects malformed, oversized, and out-of-bound entries" do
      assert {:error, :malformed_config} = RouteConcurrencyCore.new(%{"" => %{arbor: 1}})
      assert {:error, :malformed_config} = RouteConcurrencyCore.new(%{openai: %{arbor: -1}})
      assert {:error, :malformed_config} = RouteConcurrencyCore.new(%{openai: %{arbor: 10_001}})
      assert {:error, :malformed_config} = RouteConcurrencyCore.new(%{openai: "not-a-map"})
      assert {:error, :malformed_config} = RouteConcurrencyCore.new([{:openai, %{arbor: 1}}])
      assert {:error, :malformed_config} = RouteConcurrencyCore.new(%{"bad id!" => %{arbor: 1}})

      too_many_providers =
        Map.new(1..65, fn i -> {"p#{i}", %{"arbor" => 1}} end)

      assert {:error, :malformed_config} = RouteConcurrencyCore.new(too_many_providers)

      too_many_runtimes =
        %{"prov" => Map.new(1..17, fn i -> {"rt#{i}", 1} end)}

      assert {:error, :malformed_config} = RouteConcurrencyCore.new(too_many_runtimes)
    end

    test "rejects nil and boolean provider/runtime config keys as malformed_config" do
      assert {:error, :malformed_config} = RouteConcurrencyCore.new(%{nil => %{arbor: 1}})
      assert {:error, :malformed_config} = RouteConcurrencyCore.new(%{true => %{arbor: 1}})
      assert {:error, :malformed_config} = RouteConcurrencyCore.new(%{false => %{arbor: 1}})
      assert {:error, :malformed_config} = RouteConcurrencyCore.new(%{openai: %{nil => 1}})
      assert {:error, :malformed_config} = RouteConcurrencyCore.new(%{openai: %{true => 1}})
      assert {:error, :malformed_config} = RouteConcurrencyCore.new(%{openai: %{false => 1}})
    end
  end

  describe "acquire/release/snapshot" do
    setup do
      {:ok, state} =
        RouteConcurrencyCore.new(%{
          "provider_a" => %{"arbor" => 1, "acp" => 0},
          "provider_b" => %{"arbor" => 2}
        })

      %{state: state}
    end

    test "exact route isolation", %{state: state} do
      token_a = make_ref()
      token_b = make_ref()
      owner = self()

      assert {:ok, state, [{:monitor, ^owner, ^token_a}]} =
               RouteConcurrencyCore.acquire(state, :provider_a, :arbor, owner, token_a)

      # Different exact route still admits under its own limit.
      assert {:ok, state, [{:monitor, ^owner, ^token_b}]} =
               RouteConcurrencyCore.acquire(state, "provider_b", "arbor", owner, token_b)

      snap = RouteConcurrencyCore.snapshot(state)
      assert snap[{"provider_a", "arbor"}].concurrency_in_use == 1
      assert snap[{"provider_b", "arbor"}].concurrency_in_use == 1
      assert snap[{"provider_a", "acp"}].concurrency_in_use == 0
    end

    test "zero limit is at_capacity", %{state: state} do
      assert {:error, :at_capacity} =
               RouteConcurrencyCore.acquire(state, :provider_a, :acp, self(), make_ref())
    end

    test "full capacity rejects second acquire", %{state: state} do
      token1 = make_ref()
      token2 = make_ref()

      assert {:ok, state, _} =
               RouteConcurrencyCore.acquire(state, :provider_a, :arbor, self(), token1)

      assert {:error, :at_capacity} =
               RouteConcurrencyCore.acquire(state, :provider_a, :arbor, self(), token2)
    end

    test "unconfigured and malformed routes", %{state: state} do
      assert {:error, :unconfigured_route} =
               RouteConcurrencyCore.acquire(state, :missing, :arbor, self(), make_ref())

      assert {:error, :malformed_route} =
               RouteConcurrencyCore.acquire(state, "", :arbor, self(), make_ref())

      assert {:error, :malformed_route} =
               RouteConcurrencyCore.acquire(state, :provider_a, nil, self(), make_ref())
    end

    test "normalize_route rejects nil and boolean identifiers as malformed_route" do
      assert {:error, :malformed_route} = RouteConcurrencyCore.normalize_route(nil, "arbor")
      assert {:error, :malformed_route} = RouteConcurrencyCore.normalize_route("openai", nil)
      assert {:error, :malformed_route} = RouteConcurrencyCore.normalize_route(true, "arbor")
      assert {:error, :malformed_route} = RouteConcurrencyCore.normalize_route("openai", true)
      assert {:error, :malformed_route} = RouteConcurrencyCore.normalize_route(false, "arbor")
      assert {:error, :malformed_route} = RouteConcurrencyCore.normalize_route("openai", false)
      assert {:error, :malformed_route} = RouteConcurrencyCore.normalize_route(nil, nil)
      assert {:error, :malformed_route} = RouteConcurrencyCore.normalize_route(true, false)
    end

    test "idempotent release frees capacity and emits demonitor after bind", %{state: state} do
      token = make_ref()
      mon = make_ref()
      owner = self()

      assert {:ok, state, [{:monitor, ^owner, ^token}]} =
               RouteConcurrencyCore.acquire(state, :provider_a, :arbor, owner, token)

      assert {:ok, state} = RouteConcurrencyCore.bind_monitor(state, token, mon)

      assert {:ok, state, [{:demonitor, ^mon}]} = RouteConcurrencyCore.release(state, token)
      assert RouteConcurrencyCore.snapshot(state)[{"provider_a", "arbor"}].concurrency_in_use == 0

      # Second release is a no-op.
      assert {:ok, state, []} = RouteConcurrencyCore.release(state, token)
      assert RouteConcurrencyCore.snapshot(state)[{"provider_a", "arbor"}].concurrency_in_use == 0
    end

    test "owner_down reclaims capacity", %{state: state} do
      token = make_ref()
      mon = make_ref()

      assert {:ok, state, _} =
               RouteConcurrencyCore.acquire(state, :provider_a, :arbor, self(), token)

      assert {:ok, state} = RouteConcurrencyCore.bind_monitor(state, token, mon)
      assert {:ok, state, []} = RouteConcurrencyCore.owner_down(state, mon)

      assert RouteConcurrencyCore.snapshot(state)[{"provider_a", "arbor"}].concurrency_in_use == 0

      # Capacity free again.
      assert {:ok, _state, _} =
               RouteConcurrencyCore.acquire(state, :provider_a, :arbor, self(), make_ref())
    end

    test "snapshot is exact and bounded to configured routes only", %{state: state} do
      snap = RouteConcurrencyCore.snapshot(state)
      assert map_size(snap) == 3
      assert Map.has_key?(snap, {"provider_a", "arbor"})
      assert Map.has_key?(snap, {"provider_a", "acp"})
      assert Map.has_key?(snap, {"provider_b", "arbor"})
      refute Map.has_key?(snap, {"missing", "arbor"})
    end
  end

  describe "validate_snapshot/1" do
    test "accepts exact core snapshot shape" do
      {:ok, state} = RouteConcurrencyCore.new(%{openai: %{arbor: 2}})
      snap = RouteConcurrencyCore.snapshot(state)
      assert {:ok, validated} = RouteConcurrencyCore.validate_snapshot(snap)
      assert validated[{"openai", "arbor"}].concurrency_limit == 2
    end

    test "rejects malformed snapshots" do
      assert {:error, :malformed} = RouteConcurrencyCore.validate_snapshot("nope")
      assert {:error, :malformed} = RouteConcurrencyCore.validate_snapshot(%{{"a", "b"} => %{}})
    end

    test "rejects concurrency_in_use above concurrency_limit" do
      over =
        %{{"openai", "arbor"} => %{concurrency_limit: 1, concurrency_in_use: 2}}

      assert {:error, :malformed} = RouteConcurrencyCore.validate_snapshot(over)

      equal =
        %{{"openai", "arbor"} => %{concurrency_limit: 2, concurrency_in_use: 2}}

      assert {:ok, _} = RouteConcurrencyCore.validate_snapshot(equal)
    end
  end
end
