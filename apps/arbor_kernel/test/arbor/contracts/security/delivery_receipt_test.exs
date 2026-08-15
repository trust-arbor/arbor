defmodule Arbor.Contracts.Security.DeliveryReceiptTest do
  use ExUnit.Case, async: true
  @moduletag :fast
  @moduletag voice_id: "VOICE-17"

  alias Arbor.Contracts.Security.DeliveryReceipt

  @token :crypto.strong_rand_bytes(32)

  describe "new/1" do
    test "constructs the exact one-field closed shape" do
      assert {:ok, receipt} = DeliveryReceipt.new(token: @token)

      assert Map.from_struct(receipt) == %{token: @token}
      assert Map.keys(Map.from_struct(receipt)) == [:token]
    end

    test "accepts string key token as constructor input" do
      assert {:ok, receipt} = DeliveryReceipt.new(%{"token" => @token})
      assert Map.get(receipt, :token) == @token
    end

    test "rejects wrong-size, non-binary, and zero tokens" do
      assert {:error, :token_wrong_size} =
               DeliveryReceipt.new(token: :crypto.strong_rand_bytes(31))

      assert {:error, :token_wrong_size} =
               DeliveryReceipt.new(token: :crypto.strong_rand_bytes(33))

      assert {:error, :invalid_token} = DeliveryReceipt.new(token: :not_binary)
      assert {:error, :zero_token} = DeliveryReceipt.new(token: :binary.copy(<<0>>, 32))
    end

    test "rejects unknown and duplicate attributes" do
      assert {:error, :unknown_attribute} =
               DeliveryReceipt.new(token: @token, principal_id: "human_x")

      assert {:error, :duplicate_attribute} =
               DeliveryReceipt.new(%{
                 "token" => :crypto.strong_rand_bytes(32),
                 token: @token
               })

      assert {:error, :invalid_attrs} = DeliveryReceipt.new(:not_attrs)
      assert {:error, :invalid_attrs} = DeliveryReceipt.new([:token])
    end
  end

  describe "canonicalize/1 and bearer_token/1" do
    test "accepts exact DeliveryReceipt structs only" do
      assert {:ok, receipt} = DeliveryReceipt.new(token: @token)
      assert {:ok, ^receipt} = DeliveryReceipt.canonicalize(receipt)
      assert {:ok, @token} = DeliveryReceipt.bearer_token(receipt)
    end

    test "rejects raw maps, keywords, and embellished forged struct tags" do
      assert {:error, :invalid_receipt} = DeliveryReceipt.canonicalize(%{token: @token})
      assert {:error, :invalid_receipt} = DeliveryReceipt.canonicalize(token: @token)

      embellished = %{__struct__: DeliveryReceipt, token: @token, extra: true}
      assert {:error, :invalid_receipt} = DeliveryReceipt.canonicalize(embellished)

      assert {:error, :invalid_receipt} = DeliveryReceipt.bearer_token(%{token: @token})
      assert {:error, :invalid_receipt} = DeliveryReceipt.bearer_token(token: @token)
      assert {:error, :invalid_receipt} = DeliveryReceipt.bearer_token(embellished)
      assert {:error, :invalid_receipt} = DeliveryReceipt.canonicalize(:nope)
      assert {:error, :invalid_receipt} = DeliveryReceipt.bearer_token(:nope)
    end

    test "rejects exact-shape structs with invalid tokens" do
      wrong_size = %{__struct__: DeliveryReceipt, token: :crypto.strong_rand_bytes(16)}
      assert {:error, :token_wrong_size} = DeliveryReceipt.canonicalize(wrong_size)
      assert {:error, :token_wrong_size} = DeliveryReceipt.bearer_token(wrong_size)

      zero = %{__struct__: DeliveryReceipt, token: :binary.copy(<<0>>, 32)}
      assert {:error, :zero_token} = DeliveryReceipt.canonicalize(zero)
      assert {:error, :zero_token} = DeliveryReceipt.bearer_token(zero)
    end
  end

  describe "Inspect and Jason" do
    test "redacts token bytes and has no Jason encoder" do
      assert {:ok, receipt} = DeliveryReceipt.new(token: @token)
      inspected = inspect(receipt)

      assert inspected == "#Arbor.Contracts.Security.DeliveryReceipt<token: [REDACTED]>"
      refute inspected =~ Base.encode16(@token, case: :lower)
      # Protocol consolidation may select the fallback Any implementation.
      # No receipt-specific encoder exists, so encoding must still fail closed.
      assert Jason.Encoder.impl_for(receipt) in [nil, Jason.Encoder.Any]

      assert_raise Protocol.UndefinedError, fn ->
        Jason.encode!(receipt)
      end
    end
  end
end
