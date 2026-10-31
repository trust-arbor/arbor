defmodule Arbor.Contracts.Trust.ProfileTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Trust.Profile

  describe "new/1" do
    test "creates a new profile with valid agent_id" do
      assert {:ok, profile} = Profile.new("agent_123")
      assert profile.agent_id == "agent_123"
      assert profile.frozen == false
      assert profile.frozen_reason == nil
      assert profile.frozen_at == nil
    end

    test "initializes authorization rule fields" do
      {:ok, profile} = Profile.new("agent_1")
      assert profile.baseline == :ask
      assert profile.rules == %{}
    end

    test "sets created_at and updated_at timestamps" do
      {:ok, profile} = Profile.new("agent_1")
      assert %DateTime{} = profile.created_at
      assert %DateTime{} = profile.updated_at
      assert profile.last_activity_at == nil
    end

    test "returns error for empty string agent_id" do
      assert {:error, :invalid_agent_id} = Profile.new("")
    end

    test "returns error for non-string agent_id" do
      assert {:error, :invalid_agent_id} = Profile.new(123)
      assert {:error, :invalid_agent_id} = Profile.new(nil)
      assert {:error, :invalid_agent_id} = Profile.new(:atom_id)
    end
  end

  describe "freeze/2" do
    test "sets frozen to true with reason" do
      {:ok, profile} = Profile.new("agent_1")
      frozen = Profile.freeze(profile, :rapid_failures)

      assert frozen.frozen == true
      assert frozen.frozen_reason == :rapid_failures
      assert %DateTime{} = frozen.frozen_at
    end

    test "preserves other profile fields" do
      {:ok, profile} = Profile.new("agent_1")
      frozen = Profile.freeze(profile, :security_violation)

      assert frozen.agent_id == "agent_1"
      assert frozen.baseline == :ask
    end
  end

  describe "unfreeze/1" do
    test "sets frozen to false and clears reason and timestamp" do
      {:ok, profile} = Profile.new("agent_1")
      frozen = Profile.freeze(profile, :rapid_failures)
      unfrozen = Profile.unfreeze(frozen)

      assert unfrozen.frozen == false
      assert unfrozen.frozen_reason == nil
      assert unfrozen.frozen_at == nil
    end

    test "preserves other profile fields" do
      {:ok, profile} = Profile.new("agent_1")

      unfrozen =
        profile
        |> Profile.freeze(:test_reason)
        |> Profile.unfreeze()

      assert unfrozen.agent_id == "agent_1"
      assert unfrozen.baseline == :ask
    end
  end

  describe "to_map/1" do
    test "converts profile struct to a plain map" do
      {:ok, profile} = Profile.new("agent_1")
      map = Profile.to_map(profile)

      assert is_map(map)
      refute is_struct(map)
      assert map.agent_id == "agent_1"
    end

    test "includes all fields" do
      {:ok, profile} = Profile.new("agent_1")
      map = Profile.to_map(profile)

      expected_keys = [
        :agent_id,
        :frozen,
        :frozen_reason,
        :frozen_at,
        :baseline,
        :rules,
        :created_at,
        :updated_at,
        :last_activity_at
      ]

      for key <- expected_keys do
        assert Map.has_key?(map, key), "Expected map to have key #{inspect(key)}"
      end
    end

    test "does not include removed score/points fields" do
      {:ok, profile} = Profile.new("agent_1")
      map = Profile.to_map(profile)

      refute Map.has_key?(map, :trust_score)
      refute Map.has_key?(map, :trust_points)
      refute Map.has_key?(map, :tier)
      # Score/counter fields removed in the post-tier cleanup.
      refute Map.has_key?(map, :success_rate_score)
      refute Map.has_key?(map, :total_actions)
      refute Map.has_key?(map, :security_violations)
      refute Map.has_key?(map, :proposals_approved)
      refute Map.has_key?(map, :tests_passed)
    end
  end
end
