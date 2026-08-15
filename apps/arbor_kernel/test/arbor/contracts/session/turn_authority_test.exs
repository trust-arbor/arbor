defmodule Arbor.Contracts.Session.TurnAuthorityTest do
  use ExUnit.Case, async: true
  @moduletag :fast
  @moduletag voice_id: "VOICE-17"
  @moduletag spec: "VOICE-17"

  alias Arbor.Contracts.Session.TurnAuthority
  alias Arbor.Identifiers

  @valid_turn_id Identifiers.generate_id("turn_")
  @valid_human "human_alice_vp05d2a1p2"
  @valid_cap Identifiers.generate_capability_id()

  describe "new/1" do
    test "constructs the exact three-field closed shape with nil disclosure" do
      assert {:ok, auth} =
               TurnAuthority.new(
                 turn_id: @valid_turn_id,
                 authenticated_principal_id: @valid_human
               )

      assert Map.from_struct(auth) == %{
               turn_id: @valid_turn_id,
               authenticated_principal_id: @valid_human,
               disclosure_capability_id: nil
             }

      assert Enum.sort(Map.keys(Map.from_struct(auth))) == [
               :authenticated_principal_id,
               :disclosure_capability_id,
               :turn_id
             ]
    end

    test "accepts a canonical capability disclosure id" do
      assert {:ok, auth} =
               TurnAuthority.new(
                 turn_id: @valid_turn_id,
                 authenticated_principal_id: @valid_human,
                 disclosure_capability_id: @valid_cap
               )

      assert auth.disclosure_capability_id == @valid_cap
    end

    test "accepts string keys" do
      assert {:ok, auth} =
               TurnAuthority.new(%{
                 "turn_id" => @valid_turn_id,
                 "authenticated_principal_id" => @valid_human
               })

      assert auth.turn_id == @valid_turn_id
      assert auth.authenticated_principal_id == @valid_human
    end

    test "rejects missing, unknown, and duplicate attributes" do
      assert {:error, :missing_turn_id} =
               TurnAuthority.new(authenticated_principal_id: @valid_human)

      assert {:error, :missing_authenticated_principal_id} =
               TurnAuthority.new(turn_id: @valid_turn_id)

      assert {:error, :unknown_attribute} =
               TurnAuthority.new(
                 turn_id: @valid_turn_id,
                 authenticated_principal_id: @valid_human,
                 extra: true
               )

      assert {:error, :duplicate_attribute} =
               TurnAuthority.new(%{
                 "turn_id" => @valid_turn_id,
                 turn_id: Identifiers.generate_id("turn_"),
                 authenticated_principal_id: @valid_human
               })

      assert {:error, :invalid_attrs} = TurnAuthority.new(:not_attrs)
      assert {:error, :invalid_attrs} = TurnAuthority.new([:turn_id])
    end

    test "rejects malformed turn ids" do
      assert {:error, :invalid_turn_id} =
               TurnAuthority.new(
                 turn_id: "turn_ABC",
                 authenticated_principal_id: @valid_human
               )

      assert {:error, :invalid_turn_id} =
               TurnAuthority.new(
                 turn_id: "turn_" <> String.duplicate("g", 32),
                 authenticated_principal_id: @valid_human
               )

      assert {:error, :invalid_turn_id} =
               TurnAuthority.new(
                 turn_id: "session_" <> String.duplicate("a", 32),
                 authenticated_principal_id: @valid_human
               )
    end

    test "rejects non-human, oversized, NUL, and invalid UTF-8 principals" do
      assert {:error, :invalid_authenticated_principal_id} =
               TurnAuthority.new(
                 turn_id: @valid_turn_id,
                 authenticated_principal_id: "agent_" <> String.duplicate("a", 32)
               )

      oversized = "human_" <> String.duplicate("x", 300)

      assert {:error, :invalid_authenticated_principal_id} =
               TurnAuthority.new(
                 turn_id: @valid_turn_id,
                 authenticated_principal_id: oversized
               )

      assert {:error, :invalid_authenticated_principal_id} =
               TurnAuthority.new(
                 turn_id: @valid_turn_id,
                 authenticated_principal_id: "human_nul\0x"
               )

      assert {:error, :invalid_authenticated_principal_id} =
               TurnAuthority.new(
                 turn_id: @valid_turn_id,
                 authenticated_principal_id: :not_binary
               )
    end

    test "rejects malformed disclosure capability ids" do
      assert {:error, :invalid_disclosure_capability_id} =
               TurnAuthority.new(
                 turn_id: @valid_turn_id,
                 authenticated_principal_id: @valid_human,
                 disclosure_capability_id: "cap_short"
               )

      assert {:error, :invalid_disclosure_capability_id} =
               TurnAuthority.new(
                 turn_id: @valid_turn_id,
                 authenticated_principal_id: @valid_human,
                 disclosure_capability_id: "cap_" <> String.duplicate("G", 32)
               )
    end
  end

  describe "Inspect and Jason" do
    test "redacts all fields and has no Jason encoder" do
      assert {:ok, auth} =
               TurnAuthority.new(
                 turn_id: @valid_turn_id,
                 authenticated_principal_id: @valid_human,
                 disclosure_capability_id: @valid_cap
               )

      inspected = inspect(auth)

      assert inspected ==
               "#Arbor.Contracts.Session.TurnAuthority<turn_id: [REDACTED], authenticated_principal_id: [REDACTED], disclosure_capability_id: [REDACTED]>"

      refute inspected =~ @valid_turn_id
      refute inspected =~ @valid_human
      refute inspected =~ @valid_cap

      assert Jason.Encoder.impl_for(auth) in [nil, Jason.Encoder.Any]

      assert_raise Protocol.UndefinedError, fn ->
        Jason.encode!(auth)
      end
    end
  end

  describe "forged struct confers nothing" do
    test "constructing or forging TurnAuthority does not grant Security effects" do
      assert {:ok, auth} =
               TurnAuthority.new(
                 turn_id: @valid_turn_id,
                 authenticated_principal_id: @valid_human
               )

      forged = %{
        __struct__: TurnAuthority,
        turn_id: @valid_turn_id,
        authenticated_principal_id: @valid_human,
        disclosure_capability_id: nil
      }

      # Shape alone is not a capability grant or delivery receipt.
      refute function_exported?(TurnAuthority, :authorize, 1)
      refute function_exported?(TurnAuthority, :bearer_token, 1)
      assert is_struct(auth, TurnAuthority)
      assert forged.__struct__ == TurnAuthority
      # No public effect API exists on the type; forging is data only.
      assert Map.from_struct(auth) == Map.delete(forged, :__struct__)
    end
  end
end
