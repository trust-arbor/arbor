defmodule Arbor.Contracts.Security.SigningAuthorityBootstrapTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.SigningAuthorityBootstrap

  @token :crypto.strong_rand_bytes(32)
  @principal "agent_" <> String.duplicate("ab", 32)

  describe "new/1" do
    test "constructs the exact opaque restart-slot shape" do
      assert {:ok, bootstrap} =
               SigningAuthorityBootstrap.new(
                 token: @token,
                 principal_id: @principal,
                 purpose: :session
               )

      assert Map.from_struct(bootstrap) == %{
               token: @token,
               principal_id: @principal,
               purpose: :session
             }

      values = Map.values(Map.from_struct(bootstrap))
      refute Enum.any?(values, &is_pid/1)
      refute Enum.any?(values, &is_function/1)
      refute Map.has_key?(Map.from_struct(bootstrap), :private_key)
      refute Map.has_key?(Map.from_struct(bootstrap), :signer)
      refute Map.has_key?(Map.from_struct(bootstrap), :mfa)
    end

    test "accepts human principals through shared authority validation" do
      assert {:ok, bootstrap} =
               SigningAuthorityBootstrap.new(%{
                 "token" => @token,
                 "principal_id" => "human_operator_123",
                 "purpose" => "dashboard_session"
               })

      assert bootstrap.principal_id == "human_operator_123"
    end

    test "rejects invalid fields" do
      assert {:error, :token_too_short} =
               SigningAuthorityBootstrap.new(
                 token: "short",
                 principal_id: @principal,
                 purpose: :session
               )

      assert {:error, :invalid_principal_id} =
               SigningAuthorityBootstrap.new(
                 token: @token,
                 principal_id: "service_123",
                 purpose: :session
               )

      assert {:error, :invalid_purpose} =
               SigningAuthorityBootstrap.new(
                 token: @token,
                 principal_id: @principal,
                 purpose: "  "
               )
    end

    test "security regression: invalid UTF-8 and NUL principal_id fail closed; opaque bytes preserved" do
      invalid_utf8 = "agent_" <> <<0xFF>>
      with_nul = "human_ok" <> <<0>>
      spaced = @principal <> " "

      assert {:error, :invalid_principal_id} =
               SigningAuthorityBootstrap.new(
                 token: @token,
                 principal_id: invalid_utf8,
                 purpose: :session
               )

      assert {:error, :invalid_principal_id} =
               SigningAuthorityBootstrap.new(
                 token: @token,
                 principal_id: with_nul,
                 purpose: :session
               )

      assert {:ok, bootstrap} =
               SigningAuthorityBootstrap.new(
                 token: @token,
                 principal_id: spaced,
                 purpose: :session
               )

      assert bootstrap.principal_id == spaced
    end

    test "rejects all duplicate logical attributes" do
      assert {:error, :duplicate_attribute} =
               SigningAuthorityBootstrap.new(%{
                 "token" => :crypto.strong_rand_bytes(32),
                 token: @token,
                 principal_id: @principal,
                 purpose: :session
               })

      assert {:error, :duplicate_attribute} =
               SigningAuthorityBootstrap.new(
                 token: @token,
                 principal_id: @principal,
                 principal_id: "human_other",
                 purpose: :session
               )

      assert {:error, :duplicate_attribute} =
               SigningAuthorityBootstrap.new(%{
                 "token" => @token,
                 token: @token,
                 principal_id: @principal,
                 purpose: :session
               })
    end
  end

  describe "canonicalize/1 and redaction" do
    test "partial struct-tagged maps fail closed without raising" do
      partial = %{__struct__: SigningAuthorityBootstrap, token: "short"}
      assert {:error, :token_too_short} = SigningAuthorityBootstrap.canonicalize(partial)

      assert {:error, :invalid_bootstrap} = SigningAuthorityBootstrap.canonicalize(nil)
    end

    test "Inspect redacts the token and Jason encoding is unavailable" do
      {:ok, bootstrap} =
        SigningAuthorityBootstrap.new(
          token: @token,
          principal_id: @principal,
          purpose: :session
        )

      inspected = inspect(bootstrap)
      refute inspected =~ @token
      refute inspected =~ Base.encode64(@token)
      assert inspected =~ "[REDACTED]"

      assert_raise Protocol.UndefinedError, fn -> Jason.encode!(bootstrap) end

      refute function_exported?(
               Jason.Encoder.Arbor.Contracts.Security.SigningAuthorityBootstrap,
               :encode,
               2
             )
    end
  end
end
