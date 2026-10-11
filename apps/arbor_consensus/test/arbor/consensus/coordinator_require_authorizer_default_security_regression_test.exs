defmodule Arbor.Consensus.CoordinatorRequireAuthorizerDefaultSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Consensus.Coordinator

  # 2026-10-11 cross-library review F-016: the default used to be a RUNTIME
  # `Mix.env() == :prod` call — permissive in the dev daemon the operator
  # actually runs and an UndefinedFunctionError in a release (no Mix). With no
  # config at all, a missing authorizer must fail closed.
  test "security regression (F-016): require_authorizer? defaults to true without config" do
    previous = Application.get_env(:arbor_consensus, :require_authorizer)
    Application.delete_env(:arbor_consensus, :require_authorizer)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:arbor_consensus, :require_authorizer)
        value -> Application.put_env(:arbor_consensus, :require_authorizer, value)
      end
    end)

    assert Coordinator.require_authorizer?() == true
  end
end
