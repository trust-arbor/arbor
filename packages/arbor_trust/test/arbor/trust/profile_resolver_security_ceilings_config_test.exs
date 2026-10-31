defmodule Arbor.Trust.ProfileResolverSecurityCeilingsConfigTest do
  use ExUnit.Case, async: false

  alias Arbor.Trust.ProfileResolver

  @moduletag :fast

  setup do
    previous = Application.get_env(:arbor_trust, :security_ceilings)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:arbor_trust, :security_ceilings)
      else
        Application.put_env(:arbor_trust, :security_ceilings, previous)
      end
    end)

    :ok
  end

  test "application config overlays generated defaults instead of replacing them" do
    Application.put_env(:arbor_trust, :security_ceilings, %{"arbor://shell" => :block})

    ceilings = ProfileResolver.security_ceilings()

    assert ceilings["arbor://shell"] == :block
    assert ceilings["arbor://governance"] == :ask
    assert ceilings["arbor://trust/write"] == :ask
  end
end
