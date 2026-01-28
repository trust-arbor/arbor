defmodule Arbor.Security.Identity.NonceCacheTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.Identity.NonceCache

  describe "check_and_record/2" do
    test "fresh nonce returns :ok" do
      nonce = :crypto.strong_rand_bytes(16)
      assert :ok = NonceCache.check_and_record(nonce, 300)
    end

    test "replayed nonce returns error" do
      nonce = :crypto.strong_rand_bytes(16)
      assert :ok = NonceCache.check_and_record(nonce, 300)
      assert {:error, :replayed_nonce} = NonceCache.check_and_record(nonce, 300)
    end

    test "different nonces are independent" do
      nonce1 = :crypto.strong_rand_bytes(16)
      nonce2 = :crypto.strong_rand_bytes(16)

      assert :ok = NonceCache.check_and_record(nonce1, 300)
      assert :ok = NonceCache.check_and_record(nonce2, 300)
    end
  end

  describe "cleanup" do
    test "expired nonces are cleaned up" do
      # Record a nonce with a very short TTL
      nonce = :crypto.strong_rand_bytes(16)
      assert :ok = NonceCache.check_and_record(nonce, 0)

      # Trigger cleanup manually
      send(Process.whereis(NonceCache), :cleanup)
      # Give the GenServer time to process
      Process.sleep(50)

      # The nonce should be cleaned up, so recording it again should succeed
      assert :ok = NonceCache.check_and_record(nonce, 300)
    end
  end

  describe "stats/0" do
    test "tracks check and rejection counts" do
      stats_before = NonceCache.stats()

      nonce = :crypto.strong_rand_bytes(16)
      NonceCache.check_and_record(nonce, 300)
      NonceCache.check_and_record(nonce, 300)

      stats_after = NonceCache.stats()
      assert stats_after.total_checked == stats_before.total_checked + 2
      assert stats_after.total_rejected == stats_before.total_rejected + 1
    end
  end
end
