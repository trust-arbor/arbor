defmodule Arbor.Comms.OperatorResolverTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Comms
  alias Arbor.Comms.Adapters.SecurityOperatorResolver
  alias Arbor.Comms.Config

  setup do
    previous = Application.fetch_env(:arbor_comms, :signal)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_comms, :signal, value)
        :error -> Application.delete_env(:arbor_comms, :signal)
      end
    end)

    :ok
  end

  test "resolves the exact configured operator independently of Signal delivery" do
    operator = " operator_opaque "
    Application.put_env(:arbor_comms, :signal, enabled: false, interaction_user_id: operator)

    assert {:ok, ^operator} = Comms.resolve_operator_for_agent("agent_one")
    assert {:ok, ^operator} = Comms.resolve_operator_for_agent("agent_two")
    assert {:ok, ^operator} = Config.operator_user_id()
    assert {:ok, ^operator} = SecurityOperatorResolver.resolve_operator("agent_one")
  end

  test "security regression: an absent operator mapping never substitutes the agent identity" do
    Application.delete_env(:arbor_comms, :signal)

    assert {:error, :operator_not_configured} = Comms.resolve_operator_for_agent("agent_one")

    assert {:error, :operator_not_configured} =
             SecurityOperatorResolver.resolve_operator("agent_one")

    for config <- [[], [enabled: false], [interaction_user_id: nil], [interaction_user_id: ""]] do
      Application.put_env(:arbor_comms, :signal, config)

      assert {:error, :operator_not_configured} = Comms.resolve_operator_for_agent("agent_one")
    end
  end

  test "security regression: malformed Signal configuration fails closed" do
    for config <- [
          nil,
          true,
          false,
          12,
          "signal",
          %{},
          [{:interaction_user_id, "operator"}, :malformed],
          [{"interaction_user_id", "operator"}],
          [{:interaction_user_id, "operator"} | :improper]
        ] do
      Application.put_env(:arbor_comms, :signal, config)

      assert {:error, :invalid_operator_config} = Comms.resolve_operator_for_agent("agent_one")
    end
  end

  test "security regression: invalid or blank operator identities fail closed" do
    for operator <- [:operator, 12, true, false, %{}, [], ["operator"], <<255>>, " \t\r\n"] do
      Application.put_env(:arbor_comms, :signal, interaction_user_id: operator)

      assert {:error, :invalid_operator_config} = Comms.resolve_operator_for_agent("agent_one")

      assert {:error, :invalid_operator_config} =
               SecurityOperatorResolver.resolve_operator("agent_one")
    end
  end

  test "security regression: duplicate operator mappings are ambiguous even when values agree" do
    for operators <- [["operator", "other"], ["operator", "operator"], [nil, "operator"]] do
      config = Enum.map(operators, &{:interaction_user_id, &1})
      Application.put_env(:arbor_comms, :signal, config)

      assert {:error, :invalid_operator_config} = Comms.resolve_operator_for_agent("agent_one")
    end
  end

  test "rejects invalid principal identities before resolving the configured operator" do
    Application.put_env(:arbor_comms, :signal, interaction_user_id: "operator")

    for principal <- [nil, :agent, true, false, 12, %{}, [], ["agent"], "", " \t\n", <<255>>] do
      assert {:error, :invalid_principal} = Comms.resolve_operator_for_agent(principal)
      assert {:error, :invalid_principal} = SecurityOperatorResolver.resolve_operator(principal)
    end
  end

  test "legacy operator_for_agent keeps its string result and absent-mapping fallback" do
    Application.delete_env(:arbor_comms, :signal)
    assert Comms.operator_for_agent("agent_one") == "agent_one"

    for operator <- [nil, ""] do
      Application.put_env(:arbor_comms, :signal, interaction_user_id: operator)
      assert Comms.operator_for_agent("agent_one") == "agent_one"
    end

    Application.put_env(:arbor_comms, :signal, interaction_user_id: " operator_opaque ")
    assert Comms.operator_for_agent("agent_one") == " operator_opaque "
  end
end
