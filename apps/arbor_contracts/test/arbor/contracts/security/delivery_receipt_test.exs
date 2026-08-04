defmodule Arbor.Contracts.Security.DeliveryReceiptTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.DeliveryReceipt

  @token :crypto.strong_rand_bytes(32)

  describe "new/1" do
    test "constructs the exact one-field closed shape" do
      assert {:ok, receipt} = DeliveryReceipt.new(token: @token)

      assert Map.from_struct(receipt) == %{token: @token}
      assert Map.keys(Map.from_struct(receipt)) == [:token]
    end

    test "accepts string key token" do
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

  describe "canonicalize/1" do
    test "re-validates genuine receipts and rejects hostile partial maps" do
      assert {:ok, receipt} = DeliveryReceipt.new(token: @token)
      assert {:ok, ^receipt} = DeliveryReceipt.canonicalize(receipt)

      hostile = %{__struct__: DeliveryReceipt, token: :crypto.strong_rand_bytes(16)}
      assert {:error, :token_wrong_size} = DeliveryReceipt.canonicalize(hostile)
      assert {:error, :invalid_receipt} = DeliveryReceipt.canonicalize(:nope)
    end
  end

  describe "Inspect and Jason" do
    test "redacts token bytes and has no Jason encoder" do
      assert {:ok, receipt} = DeliveryReceipt.new(token: @token)
      inspected = inspect(receipt)

      assert inspected == "#Arbor.Contracts.Security.DeliveryReceipt<token: [REDACTED]>"
      refute inspected =~ Base.encode16(@token, case: :lower)
      assert is_nil(Jason.Encoder.impl_for(receipt))

      assert_raise Protocol.UndefinedError, fn ->
        Jason.encode!(receipt)
      end
    end
  end
end
