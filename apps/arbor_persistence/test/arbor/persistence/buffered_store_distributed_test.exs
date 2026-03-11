defmodule Arbor.Persistence.BufferedStore.DistributedTest do
  @moduledoc """
  Tests for BufferedStore distributed cache invalidation.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Persistence.BufferedStore

  @test_store :buffered_store_dist_test

  setup do
    pid = start_supervised!({BufferedStore, name: @test_store, distributed: true})
    %{store_pid: pid}
  end

  # ── Remote Put Signal → Reload ───────────────────────────────────────

  describe "remote put signal handling" do
    test "invalidates ETS on remote cache_put signal" do
      # Write a value locally
      :ok = BufferedStore.put("key1", "local_value", name: @test_store)
      assert {:ok, "local_value"} = BufferedStore.get("key1", name: @test_store)

      # Simulate a remote cache_put signal
      # Since we have no backend, this will just delete the key
      send(Process.whereis(@test_store), {:signal_received, %{
        type: :cache_put,
        data: %{
          collection: to_string(@test_store),
          key: "key1",
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      # With no backend, the key is removed from ETS
      assert {:error, :not_found} = BufferedStore.get("key1", name: @test_store)
    end

    test "ignores put signals from own node" do
      :ok = BufferedStore.put("key2", "my_value", name: @test_store)

      send(Process.whereis(@test_store), {:signal_received, %{
        type: :cache_put,
        data: %{
          collection: to_string(@test_store),
          key: "key2",
          origin_node: node()
        }
      }})

      Process.sleep(10)

      # Should still be cached — signal from own node is ignored
      assert {:ok, "my_value"} = BufferedStore.get("key2", name: @test_store)
    end

    test "ignores signals for other collections" do
      :ok = BufferedStore.put("key3", "keep_me", name: @test_store)

      send(Process.whereis(@test_store), {:signal_received, %{
        type: :cache_put,
        data: %{
          collection: "different_collection",
          key: "key3",
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      # Should still be cached — signal is for a different collection
      assert {:ok, "keep_me"} = BufferedStore.get("key3", name: @test_store)
    end
  end

  # ── Remote Delete Signal ─────────────────────────────────────────────

  describe "remote delete signal handling" do
    test "deletes ETS entry on remote cache_delete signal" do
      :ok = BufferedStore.put("key4", "delete_me", name: @test_store)
      assert {:ok, "delete_me"} = BufferedStore.get("key4", name: @test_store)

      send(Process.whereis(@test_store), {:signal_received, %{
        type: :cache_delete,
        data: %{
          collection: to_string(@test_store),
          key: "key4",
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      assert {:error, :not_found} = BufferedStore.get("key4", name: @test_store)
    end
  end

  # ── Non-distributed Mode ─────────────────────────────────────────────

  describe "non-distributed mode" do
    test "does not emit signals when distributed: false" do
      non_dist_store = :buffered_store_non_dist_test

      start_supervised!(
        {BufferedStore, name: non_dist_store, distributed: false},
        id: :non_dist
      )

      # Should work fine without any signal infrastructure
      :ok = BufferedStore.put("key", "value", name: non_dist_store)
      assert {:ok, "value"} = BufferedStore.get("key", name: non_dist_store)
    end
  end

  # ── Robustness ───────────────────────────────────────────────────────

  describe "robustness" do
    test "handles unknown signal types gracefully" do
      send(Process.whereis(@test_store), {:signal_received, %{
        type: :unknown_type,
        data: %{
          collection: to_string(@test_store),
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      assert Process.alive?(Process.whereis(@test_store))
    end

    test "handles random messages gracefully" do
      send(Process.whereis(@test_store), :random_message)
      send(Process.whereis(@test_store), {:unexpected, :data})

      Process.sleep(10)

      assert Process.alive?(Process.whereis(@test_store))
    end
  end
end
