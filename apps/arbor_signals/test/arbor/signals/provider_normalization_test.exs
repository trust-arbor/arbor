defmodule Arbor.Signals.ProviderNormalizationTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Signals.Provider

  test "resolves absent invalid and missing callbacks" do
    assert Provider.resolve(nil, :authorize, 4) == {:error, :absent}
    assert Provider.resolve(true, :authorize, 4) == {:error, :invalid_provider}
    assert Provider.resolve(false, :authorize, 4) == {:error, :invalid_provider}
    assert Provider.resolve("not-a-module", :authorize, 4) == {:error, :invalid_provider}

    assert Provider.resolve(__MODULE__.Empty, :authorize, 4) == {:error, :missing_callback}

    assert Provider.resolve(This.Module.Does.Not.Exist, :authorize, 4) ==
             {:error, :missing_callback}

    assert Provider.resolve(nil, :lookup, 1) == {:error, :absent}
    assert Provider.resolve(nil, :lookup_encryption_key, 1) == {:error, :absent}
    assert Provider.resolve(true, :lookup, 1) == {:error, :invalid_provider}

    assert Provider.resolve("not-a-module", :lookup_encryption_key, 1) ==
             {:error, :invalid_provider}

    assert Provider.resolve(__MODULE__.Empty, :lookup, 1) == {:error, :missing_callback}

    assert Provider.resolve(__MODULE__.Empty, :lookup_encryption_key, 1) ==
             {:error, :missing_callback}
  end

  test "invokes exported callbacks and normalizes raise throw exit" do
    assert {:ok, __MODULE__.Ok} = Provider.resolve(__MODULE__.Ok, :ping, 0)
    assert Provider.invoke(__MODULE__.Ok, :ping, []) == {:ok, :pong}

    assert {:error, :provider_raised, RuntimeError} =
             Provider.invoke(__MODULE__.Raise, :ping, [])

    assert Provider.invoke(__MODULE__.Throw, :ping, []) == {:error, :provider_threw}
    assert Provider.invoke(__MODULE__.Exit, :ping, []) == {:error, :provider_exited}
  end

  defmodule Empty do
  end

  defmodule Ok do
    def ping, do: :pong
  end

  defmodule Raise do
    def ping, do: raise("boom")
  end

  defmodule Throw do
    def ping, do: throw(:boom)
  end

  defmodule Exit do
    def ping, do: exit(:boom)
  end
end
