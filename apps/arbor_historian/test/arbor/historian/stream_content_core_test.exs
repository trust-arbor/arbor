defmodule Arbor.Historian.StreamContent.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Historian.StreamContent.Core

  @moduletag :fast
  @moduletag spec: "VP-05D2C3I0C4C"

  describe "admit/2" do
    test "accepts valid stream id and default timeout" do
      assert {:ok, %{timeout_ms: 5_000}} = Core.admit("agent:alice", [])
    end

    test "accepts bounded timeout_ms" do
      assert {:ok, %{timeout_ms: 1}} = Core.admit("s", timeout_ms: 1)
      assert {:ok, %{timeout_ms: 60_000}} = Core.admit("s", timeout_ms: 60_000)
    end

    test "rejects invalid stream ids" do
      assert {:error, :invalid_stream_id} = Core.admit("", [])
      assert {:error, :invalid_stream_id} = Core.admit(:atom, [])
      assert {:error, :invalid_stream_id} = Core.admit(String.duplicate("x", 256), [])
    end

    test "rejects invalid options as invalid_precondition" do
      assert {:error, :invalid_precondition} = Core.admit("s", timeout_ms: 0)
      assert {:error, :invalid_precondition} = Core.admit("s", timeout_ms: 60_001)
      assert {:error, :invalid_precondition} = Core.admit("s", repo: :nope)
      assert {:error, :invalid_precondition} = Core.admit("s", %{timeout_ms: 1})
      assert {:error, :invalid_precondition} =
               Core.admit("s", [{:timeout_ms, 1}, {:timeout_ms, 2}])
    end
  end

  describe "progress and classification" do
    test "purge ok never advances progress; only absence proofs do" do
      assert :none_proven_absent ==
               Core.advance_progress(:none_proven_absent, :durable, {:ok, false})

      assert :durable_proven_absent ==
               Core.advance_progress(:none_proven_absent, :durable, {:ok, true})

      assert :durable_and_hot_proven_absent ==
               Core.advance_progress(:durable_proven_absent, :hot, {:ok, true})
    end

    test "classify purge pre vs uncertain vs ok" do
      assert :dispatched_ok = Core.classify_purge_reply(:durable, :ok)

      assert {:pre, :durable_unavailable} =
               Core.classify_purge_reply(:durable, {:error, :backend_unavailable})

      assert {:pre, :hot_unavailable} =
               Core.classify_purge_reply(:hot, {:error, :backend_unavailable})

      assert {:pre, :delete_not_supported} =
               Core.classify_purge_reply(:durable, {:error, :purge_not_supported})

      assert :uncertain =
               Core.classify_purge_reply(:durable, {:error, {:purge_indeterminate, "s"}})

      assert :uncertain = Core.classify_purge_reply(:durable, {:ok, :deleted})
      assert :uncertain = Core.classify_purge_reply(:hot, :raise_me)
    end

    test "classify absence proofs and uncertainty" do
      assert {:proof, true} = Core.classify_absence_reply(:durable, {:ok, true})
      assert {:proof, false} = Core.classify_absence_reply(:hot, {:ok, false})

      assert {:pre, :absence_not_supported} =
               Core.classify_absence_reply(:durable, {:error, :absence_not_supported})

      assert :uncertain =
               Core.classify_absence_reply(:hot, {:error, {:absence_indeterminate, "s"}})

      assert :uncertain = Core.classify_absence_reply(:durable, true)
    end

    test "Keyword.put remaining budget overwrites stale timeout keys" do
      static = [repo: :Repo, purge_timeout_ms: 1, absence_timeout_ms: 1]

      purge_opts = Core.put_remaining_budget(static, :purge, 42)
      assert Keyword.get(purge_opts, :purge_timeout_ms) == 42
      assert Keyword.get(purge_opts, :repo) == :Repo

      absence_opts = Core.put_remaining_budget(static, :absence, 99)
      assert Keyword.get(absence_opts, :absence_timeout_ms) == 99
    end

    test "remaining_ms reports exhaustion" do
      assert {:ok, 5} = Core.remaining_ms(10, 5)
      assert :exhausted = Core.remaining_ms(10, 10)
      assert :exhausted = Core.remaining_ms(10, 11)
    end
  end
end
