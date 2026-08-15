defmodule Arbor.Contracts.Security.IdentityStatusTest do
  @moduledoc """
  Tests for Identity struct status fields:
  - Default status value
  - valid_status?/1 function
  - public_only/1 preserves status
  - Jason encoding includes status
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Security.Identity

  # ===========================================================================
  # Default status value
  # ===========================================================================

  describe "default status" do
    test "Identity.generate/1 defaults to :active status" do
      {:ok, identity} = Identity.generate()

      assert identity.status == :active
    end

    test "Identity.new/1 defaults to :active status" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, identity} = Identity.new(public_key: public_key)

      assert identity.status == :active
    end

    test "status_changed_at defaults to nil" do
      {:ok, identity} = Identity.generate()

      assert identity.status_changed_at == nil
    end

    test "status_reason defaults to nil" do
      {:ok, identity} = Identity.generate()

      assert identity.status_reason == nil
    end
  end

  # ===========================================================================
  # Custom status on creation
  # ===========================================================================

  describe "custom status on creation" do
    test "can specify status explicitly" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, identity} = Identity.new(public_key: public_key, status: :suspended)

      assert identity.status == :suspended
    end

    test "can specify status_changed_at" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)
      timestamp = DateTime.utc_now()

      {:ok, identity} = Identity.new(public_key: public_key, status_changed_at: timestamp)

      assert identity.status_changed_at == timestamp
    end

    test "can specify status_reason" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, identity} = Identity.new(public_key: public_key, status_reason: "Initial suspension")

      assert identity.status_reason == "Initial suspension"
    end
  end

  # ===========================================================================
  # valid_status?/1 function
  # ===========================================================================

  describe "Identity.valid_status?/1" do
    test "returns true for :active" do
      assert Identity.valid_status?(:active)
    end

    test "returns true for :suspended" do
      assert Identity.valid_status?(:suspended)
    end

    test "returns true for :revoked" do
      assert Identity.valid_status?(:revoked)
    end

    test "returns false for invalid atom" do
      refute Identity.valid_status?(:invalid)
      refute Identity.valid_status?(:pending)
      refute Identity.valid_status?(:disabled)
    end

    test "returns false for non-atom values" do
      refute Identity.valid_status?("active")
      refute Identity.valid_status?(1)
      refute Identity.valid_status?(nil)
      refute Identity.valid_status?([])
    end
  end

  # ===========================================================================
  # public_only/1 preserves status
  # ===========================================================================

  describe "public_only/1 and status" do
    test "preserves :active status" do
      {:ok, identity} = Identity.generate()
      assert identity.status == :active

      public = Identity.public_only(identity)
      assert public.status == :active
    end

    test "preserves :suspended status" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, identity} = Identity.new(public_key: public_key, status: :suspended)

      public = Identity.public_only(identity)
      assert public.status == :suspended
    end

    test "preserves :revoked status" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, identity} = Identity.new(public_key: public_key, status: :revoked)

      public = Identity.public_only(identity)
      assert public.status == :revoked
    end

    test "preserves status_changed_at" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)
      timestamp = DateTime.utc_now()

      {:ok, identity} =
        Identity.new(public_key: public_key, status_changed_at: timestamp)

      public = Identity.public_only(identity)
      assert public.status_changed_at == timestamp
    end

    test "preserves status_reason" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, identity} =
        Identity.new(public_key: public_key, status_reason: "Audit requirement")

      public = Identity.public_only(identity)
      assert public.status_reason == "Audit requirement"
    end
  end

  # ===========================================================================
  # Jason encoding includes status
  # ===========================================================================

  describe "Jason encoding and status" do
    test "includes status in JSON output" do
      {:ok, identity} = Identity.generate()
      json = Jason.encode!(identity)
      decoded = Jason.decode!(json)

      assert Map.has_key?(decoded, "status")
      assert decoded["status"] == "active"
    end

    test "includes status_changed_at when set" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)
      timestamp = DateTime.utc_now()

      {:ok, identity} =
        Identity.new(public_key: public_key, status_changed_at: timestamp)

      json = Jason.encode!(identity)
      decoded = Jason.decode!(json)

      assert Map.has_key?(decoded, "status_changed_at")
      assert decoded["status_changed_at"] == DateTime.to_iso8601(timestamp)
    end

    test "status_changed_at is null when not set" do
      {:ok, identity} = Identity.generate()
      json = Jason.encode!(identity)
      decoded = Jason.decode!(json)

      # null values are included in the JSON
      assert Map.has_key?(decoded, "status_changed_at")
      assert decoded["status_changed_at"] == nil
    end

    test "includes status_reason in JSON output" do
      {public_key, _private_key} = :crypto.generate_key(:eddsa, :ed25519)

      {:ok, identity} =
        Identity.new(public_key: public_key, status_reason: "Test reason")

      json = Jason.encode!(identity)
      decoded = Jason.decode!(json)

      assert Map.has_key?(decoded, "status_reason")
      assert decoded["status_reason"] == "Test reason"
    end
  end
end
