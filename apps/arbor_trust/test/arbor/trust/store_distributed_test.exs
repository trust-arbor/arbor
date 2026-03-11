defmodule Arbor.Trust.Store.DistributedTest do
  @moduledoc """
  Tests for distributed trust profile cache invalidation via signals.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.Store

  setup do
    start_supervised!({Store, []})
    :ok
  end

  describe "distributed cache invalidation" do
    test "invalidates profile cache on remote profile_updated signal" do
      {:ok, profile} = Profile.new("agent_dist_trust_#{System.unique_integer([:positive])}")
      :ok = Store.store_profile(profile)

      assert {:ok, _} = Store.get_profile(profile.agent_id)

      send(Process.whereis(Store), {:signal_received, %{
        type: :profile_updated,
        data: %{
          agent_id: profile.agent_id,
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      # Cache should be invalidated — returns :not_found (no DB fallback in test)
      assert {:error, :not_found} = Store.get_profile(profile.agent_id)
    end

    test "deletes profile cache on remote profile_deleted signal" do
      {:ok, profile} = Profile.new("agent_dist_del_#{System.unique_integer([:positive])}")
      :ok = Store.store_profile(profile)

      send(Process.whereis(Store), {:signal_received, %{
        type: :profile_deleted,
        data: %{
          agent_id: profile.agent_id,
          origin_node: :remote@node
        }
      }})

      Process.sleep(10)

      assert {:error, :not_found} = Store.get_profile(profile.agent_id)
    end

    test "ignores signals from own node" do
      {:ok, profile} = Profile.new("agent_dist_self_#{System.unique_integer([:positive])}")
      :ok = Store.store_profile(profile)

      send(Process.whereis(Store), {:signal_received, %{
        type: :profile_updated,
        data: %{
          agent_id: profile.agent_id,
          origin_node: node()
        }
      }})

      Process.sleep(10)

      assert {:ok, _} = Store.get_profile(profile.agent_id)
    end

    test "handles unknown signal types gracefully" do
      send(Process.whereis(Store), {:signal_received, %{
        type: :unknown_type,
        data: %{origin_node: :remote@node}
      }})

      Process.sleep(10)

      assert Process.alive?(Process.whereis(Store))
    end
  end
end
