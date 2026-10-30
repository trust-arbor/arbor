defmodule Arbor.Capabilities.Signals.ContractsTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Capabilities.Signals

  test "the explicit adapter owns all three Signals provider behaviors" do
    behaviours =
      Signals.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Arbor.Signals.Contracts.Authorization in behaviours
    assert Arbor.Signals.Contracts.Crypto in behaviours
    assert Arbor.Signals.Contracts.IdentityKeys in behaviours
  end
end
