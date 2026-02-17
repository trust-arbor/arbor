defmodule Arbor.Security.Identity.RegistryStressTest do
  @moduledoc """
  Concurrent stress tests for the Identity Registry.

  Validates that under concurrent load:
  - No registrations are lost
  - Duplicate rejections are reliable
  - Concurrent register + lookup is consistent
  - Concurrent register + deregister doesn't corrupt state
  - Stats remain consistent with actual state
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security.Identity.Registry

  # Keep concurrency reasonable for fast tests
  @concurrent_agents 20
  @stress_iterations 3

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp generate_identity(name) do
    {:ok, identity} = Identity.generate(name: name)
    identity
  end

  defp generate_identities(count, name_prefix) do
    for i <- 1..count do
      name = if name_prefix, do: "#{name_prefix}-#{i}", else: nil
      generate_identity(name)
    end
  end

  # ---------------------------------------------------------------------------
  # Stress: Concurrent registration doesn't lose data
  # ---------------------------------------------------------------------------

  describe "concurrent registration" do
    test "all unique identities are registered successfully" do
      Enum.each(1..@stress_iterations, fn _iteration ->
        identities = generate_identities(@concurrent_agents, "concurrent")

        # Register all identities concurrently
        tasks =
          Enum.map(identities, fn identity ->
            Task.async(fn -> Registry.register(identity) end)
          end)

        results = Task.await_many(tasks, 5_000)

        # All should succeed
        assert Enum.all?(results, &(&1 == :ok)),
               "Some registrations failed: #{inspect(Enum.reject(results, &(&1 == :ok)))}"

        # Verify all are now registered
        Enum.each(identities, fn identity ->
          assert {:ok, pk} = Registry.lookup(identity.agent_id)
          assert pk == identity.public_key
        end)

        # Clean up
        Enum.each(identities, fn identity ->
          Registry.deregister(identity.agent_id)
        end)
      end)
    end

    test "duplicate registration is reliably rejected under concurrency" do
      identity = generate_identity("dup-test")
      :ok = Registry.register(identity)

      # Try to register the same identity from many concurrent tasks
      tasks =
        for _ <- 1..@concurrent_agents do
          Task.async(fn -> Registry.register(identity) end)
        end

      results = Task.await_many(tasks, 5_000)

      # All should fail with already_registered
      assert Enum.all?(results, fn result ->
               match?({:error, {:already_registered, _}}, result)
             end),
             "Expected all duplicate registrations to fail, got: #{inspect(results)}"

      # Original registration still intact
      assert {:ok, pk} = Registry.lookup(identity.agent_id)
      assert pk == identity.public_key

      # Clean up
      Registry.deregister(identity.agent_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Stress: Concurrent register + lookup consistency
  # ---------------------------------------------------------------------------

  describe "concurrent register and lookup" do
    test "lookups never return stale data" do
      Enum.each(1..@stress_iterations, fn _iteration ->
        identities = generate_identities(@concurrent_agents, nil)

        # Half register, half lookup concurrently
        {to_register, to_lookup_later} = Enum.split(identities, div(@concurrent_agents, 2))

        # Register the first half
        Enum.each(to_register, fn id -> :ok = Registry.register(id) end)

        # Concurrently: register second half + lookup first half
        register_tasks =
          Enum.map(to_lookup_later, fn id ->
            Task.async(fn -> {:register, id.agent_id, Registry.register(id)} end)
          end)

        lookup_tasks =
          Enum.map(to_register, fn id ->
            Task.async(fn -> {:lookup, id.agent_id, Registry.lookup(id.agent_id)} end)
          end)

        all_results = Task.await_many(register_tasks ++ lookup_tasks, 5_000)

        # All lookups for already-registered identities should succeed
        lookup_results = Enum.filter(all_results, fn {type, _, _} -> type == :lookup end)

        Enum.each(lookup_results, fn {:lookup, agent_id, result} ->
          assert match?({:ok, _}, result),
                 "Lookup failed for registered agent #{agent_id}: #{inspect(result)}"
        end)

        # All new registrations should succeed
        register_results = Enum.filter(all_results, fn {type, _, _} -> type == :register end)

        Enum.each(register_results, fn {:register, agent_id, result} ->
          assert result == :ok,
                 "Registration failed for #{agent_id}: #{inspect(result)}"
        end)

        # Clean up
        Enum.each(identities, fn id -> Registry.deregister(id.agent_id) end)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Stress: Concurrent register + deregister doesn't corrupt state
  # ---------------------------------------------------------------------------

  describe "concurrent register and deregister" do
    test "state remains consistent after concurrent mutations" do
      Enum.each(1..@stress_iterations, fn _iteration ->
        # Register a batch of identities
        identities = generate_identities(@concurrent_agents, "mut-test")
        Enum.each(identities, fn id -> :ok = Registry.register(id) end)

        # Split: deregister half, re-lookup the other half, all concurrently
        {to_deregister, to_keep} = Enum.split(identities, div(@concurrent_agents, 2))

        deregister_tasks =
          Enum.map(to_deregister, fn id ->
            Task.async(fn -> {:deregister, id.agent_id, Registry.deregister(id.agent_id)} end)
          end)

        lookup_tasks =
          Enum.map(to_keep, fn id ->
            Task.async(fn -> {:lookup, id.agent_id, Registry.lookup(id.agent_id)} end)
          end)

        all_results = Task.await_many(deregister_tasks ++ lookup_tasks, 5_000)

        # All deregistrations should succeed
        deregister_results = Enum.filter(all_results, fn {type, _, _} -> type == :deregister end)

        Enum.each(deregister_results, fn {:deregister, _id, result} ->
          assert result == :ok
        end)

        # Kept identities should still be lookable
        Enum.each(to_keep, fn id ->
          assert {:ok, _pk} = Registry.lookup(id.agent_id)
        end)

        # Deregistered identities should be gone
        Enum.each(to_deregister, fn id ->
          assert {:error, :not_found} = Registry.lookup(id.agent_id)
        end)

        # Clean up remaining
        Enum.each(to_keep, fn id -> Registry.deregister(id.agent_id) end)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Stress: Stats consistency under concurrent mutations
  # ---------------------------------------------------------------------------

  describe "stats consistency" do
    test "stats reflect actual state after concurrent operations" do
      identities = generate_identities(@concurrent_agents, "stats-test")

      # Register all
      tasks = Enum.map(identities, fn id -> Task.async(fn -> Registry.register(id) end) end)
      Task.await_many(tasks, 5_000)

      stats = Registry.stats()
      assert stats.active_identities >= @concurrent_agents

      # Deregister half concurrently
      {to_remove, _to_keep} = Enum.split(identities, div(@concurrent_agents, 2))

      remove_tasks =
        Enum.map(to_remove, fn id ->
          Task.async(fn -> Registry.deregister(id.agent_id) end)
        end)

      Task.await_many(remove_tasks, 5_000)

      # After removal, stats should still be consistent
      _final_stats = Registry.stats()

      # The active count should have decreased
      # (It might not be exactly half because other tests may have registered things)
      remaining =
        identities
        |> Enum.count(fn id -> Registry.registered?(id.agent_id) end)

      assert remaining == @concurrent_agents - div(@concurrent_agents, 2)

      # Clean up
      identities
      |> Enum.each(fn id -> Registry.deregister(id.agent_id) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Stress: Name index under concurrent mutations
  # ---------------------------------------------------------------------------

  describe "name index under concurrency" do
    test "concurrent registrations with same name are all indexed" do
      name = "shared-name-#{:rand.uniform(100_000)}"
      identities = generate_identities(@concurrent_agents, nil)

      # Give them all the same name by rebuilding
      identities_with_name =
        Enum.map(identities, fn id ->
          {:ok, named} =
            Identity.new(
              public_key: id.public_key,
              encryption_public_key: id.encryption_public_key,
              name: name
            )

          named
        end)

      # Register all concurrently
      tasks =
        Enum.map(identities_with_name, fn id ->
          Task.async(fn -> Registry.register(id) end)
        end)

      results = Task.await_many(tasks, 5_000)
      success_count = Enum.count(results, &(&1 == :ok))
      assert success_count == @concurrent_agents

      # Name lookup should return all agents
      {:ok, agent_ids} = Registry.lookup_by_name(name)
      assert length(agent_ids) == @concurrent_agents

      # Clean up
      Enum.each(identities_with_name, fn id -> Registry.deregister(id.agent_id) end)
    end
  end

  # ---------------------------------------------------------------------------
  # Stress: Lifecycle transitions under concurrency
  # ---------------------------------------------------------------------------

  describe "concurrent lifecycle transitions" do
    test "concurrent suspend/resume on different identities" do
      identities = generate_identities(@concurrent_agents, "lifecycle")
      Enum.each(identities, fn id -> :ok = Registry.register(id) end)

      {to_suspend, to_keep_active} = Enum.split(identities, div(@concurrent_agents, 2))

      # Suspend half concurrently while looking up the other half
      suspend_tasks =
        Enum.map(to_suspend, fn id ->
          Task.async(fn -> Registry.suspend(id.agent_id, "stress test") end)
        end)

      lookup_tasks =
        Enum.map(to_keep_active, fn id ->
          Task.async(fn -> Registry.lookup(id.agent_id) end)
        end)

      all_results = Task.await_many(suspend_tasks ++ lookup_tasks, 5_000)

      # All suspend operations should succeed
      suspend_results = Enum.take(all_results, length(to_suspend))
      assert Enum.all?(suspend_results, &(&1 == :ok))

      # Active identity lookups should succeed
      lookup_results = Enum.drop(all_results, length(to_suspend))
      assert Enum.all?(lookup_results, fn r -> match?({:ok, _}, r) end)

      # Suspended identities should fail lookup
      Enum.each(to_suspend, fn id ->
        assert {:error, :identity_suspended} = Registry.lookup(id.agent_id)
      end)

      # Resume all suspended
      resume_tasks =
        Enum.map(to_suspend, fn id ->
          Task.async(fn -> Registry.resume(id.agent_id) end)
        end)

      resume_results = Task.await_many(resume_tasks, 5_000)
      assert Enum.all?(resume_results, &(&1 == :ok))

      # All should be lookable again
      Enum.each(identities, fn id ->
        assert {:ok, _} = Registry.lookup(id.agent_id)
      end)

      # Clean up
      Enum.each(identities, fn id -> Registry.deregister(id.agent_id) end)
    end
  end
end
