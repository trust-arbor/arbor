defmodule Arbor.Contracts.Security.SigningAuthorityTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.SigningAuthority

  @valid_token :crypto.strong_rand_bytes(32)
  @valid_principal "agent_" <> String.duplicate("ab", 32)

  describe "new/1 factory validation" do
    test "accepts valid token, principal, and purpose atom" do
      assert {:ok, authority} =
               SigningAuthority.new(
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: :session
               )

      assert authority.token == @valid_token
      assert authority.principal_id == @valid_principal
      assert authority.purpose == :session
    end

    test "accepts string purpose" do
      assert {:ok, authority} =
               SigningAuthority.new(
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: "coding_task"
               )

      assert authority.purpose == "coding_task"
    end

    test "rejects missing token" do
      assert {:error, :invalid_token} =
               SigningAuthority.new(principal_id: @valid_principal, purpose: :session)
    end

    test "rejects short token" do
      assert {:error, :token_too_short} =
               SigningAuthority.new(
                 token: <<1, 2, 3>>,
                 principal_id: @valid_principal,
                 purpose: :session
               )
    end

    test "rejects all-zero token" do
      assert {:error, :zero_token} =
               SigningAuthority.new(
                 token: :binary.copy(<<0>>, 32),
                 principal_id: @valid_principal,
                 purpose: :session
               )
    end

    test "accepts human principals" do
      assert {:ok, authority} =
               SigningAuthority.new(
                 token: @valid_token,
                 principal_id: "human_operator_123",
                 purpose: :session
               )

      assert authority.principal_id == "human_operator_123"
    end

    test "rejects principals outside the agent and human namespaces" do
      assert {:error, :invalid_principal_id} =
               SigningAuthority.new(
                 token: @valid_token,
                 principal_id: "service_abc",
                 purpose: :session
               )
    end

    test "rejects empty, blank/whitespace, boolean, or nil purpose" do
      assert {:error, :invalid_purpose} =
               SigningAuthority.new(
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: ""
               )

      assert {:error, :invalid_purpose} =
               SigningAuthority.new(
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: "   "
               )

      assert {:error, :invalid_purpose} =
               SigningAuthority.new(
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: "\t\n"
               )

      assert {:error, :invalid_purpose} =
               SigningAuthority.new(
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: true
               )

      assert {:error, :invalid_purpose} =
               SigningAuthority.new(
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: false
               )

      assert {:error, :invalid_purpose} =
               SigningAuthority.new(
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: nil
               )
    end

    test "accepts map attrs and rejects blank purpose via map path" do
      assert {:ok, authority} =
               SigningAuthority.new(%{
                 "token" => @valid_token,
                 "principal_id" => @valid_principal,
                 "purpose" => "coding_task"
               })

      assert authority.purpose == "coding_task"

      assert {:error, :invalid_purpose} =
               SigningAuthority.new(%{
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: "  "
               })
    end

    test "rejects all duplicate logical attributes" do
      assert {:error, :duplicate_attribute} =
               SigningAuthority.new(%{
                 "token" => :crypto.strong_rand_bytes(32),
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: :session
               })

      assert {:error, :duplicate_attribute} =
               SigningAuthority.new(
                 token: @valid_token,
                 token: :crypto.strong_rand_bytes(32),
                 principal_id: @valid_principal,
                 purpose: :session
               )

      assert {:error, :duplicate_attribute} =
               SigningAuthority.new(%{
                 "token" => @valid_token,
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: :session
               })
    end

    test "rejects unknown and malformed attributes" do
      assert {:error, :unknown_attribute} =
               SigningAuthority.new(
                 token: @valid_token,
                 principal_id: @valid_principal,
                 purpose: :session,
                 private_key: :crypto.strong_rand_bytes(32)
               )

      assert {:error, :invalid_attrs} = SigningAuthority.new([:malformed])
    end
  end

  describe "Inspect redaction" do
    test "does not leak the bearer token" do
      {:ok, authority} =
        SigningAuthority.new(
          token: @valid_token,
          principal_id: @valid_principal,
          purpose: :session
        )

      inspected = inspect(authority)

      refute inspected =~ @valid_token
      refute inspected =~ Base.encode64(@valid_token)
      refute inspected =~ Base.encode16(@valid_token, case: :lower)
      assert inspected =~ "[REDACTED]"
      assert inspected =~ @valid_principal
      assert inspected =~ "session"
    end
  end

  describe "JSON encoding rejection" do
    test "has no Jason.Encoder derive and raises on encode" do
      {:ok, authority} =
        SigningAuthority.new(
          token: @valid_token,
          principal_id: @valid_principal,
          purpose: :session
        )

      # Must not accidentally serialize into checkpoints / logs.
      assert_raise Protocol.UndefinedError, fn ->
        Jason.encode!(authority)
      end
    end

    test "module source does not derive Jason.Encoder" do
      {:ok, authority} =
        SigningAuthority.new(
          token: @valid_token,
          principal_id: @valid_principal,
          purpose: :session
        )

      refute function_exported?(
               Jason.Encoder.Arbor.Contracts.Security.SigningAuthority,
               :encode,
               2
             )

      refute is_function(authority.token)
      assert is_binary(authority.token)
    end
  end

  describe "signing_authority?/1" do
    test "recognizes structs only" do
      {:ok, authority} =
        SigningAuthority.new(
          token: @valid_token,
          principal_id: @valid_principal,
          purpose: :session
        )

      assert SigningAuthority.signing_authority?(authority)
      refute SigningAuthority.signing_authority?(%{token: @valid_token})
      refute SigningAuthority.signing_authority?(nil)
    end
  end

  describe "canonicalize/1" do
    test "re-validates complete structs" do
      {:ok, authority} =
        SigningAuthority.new(
          token: @valid_token,
          principal_id: @valid_principal,
          purpose: :session
        )

      assert {:ok, ^authority} = SigningAuthority.canonicalize(authority)
    end

    test "partial struct-tagged maps fail closed without raising" do
      partial = %{__struct__: SigningAuthority, token: "too-short"}

      assert {:error, :token_too_short} = SigningAuthority.canonicalize(partial)

      missing_fields = %{__struct__: SigningAuthority}
      assert {:error, :invalid_token} = SigningAuthority.canonicalize(missing_fields)
    end

    test "rejects non-authority terms" do
      assert {:error, :invalid_authority} = SigningAuthority.canonicalize(nil)
      assert {:error, :invalid_authority} = SigningAuthority.canonicalize(:atom)
    end
  end
end
