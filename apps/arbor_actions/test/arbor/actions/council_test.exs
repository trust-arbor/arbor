defmodule Arbor.Actions.CouncilTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.Council

  @moduletag :fast

  describe "Consult" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Council.Consult.validate_params(%{})

      # Test that schema accepts valid params with just question
      assert {:ok, _} =
               Council.Consult.validate_params(%{
                 question: "Should we use Redis or ETS for caching?"
               })

      # Test with all optional params
      assert {:ok, _} =
               Council.Consult.validate_params(%{
                 question: "Should we use Redis or ETS for caching?",
                 context: %{constraints: "must survive restarts"},
                 timeout: 120_000,
                 evaluator: Arbor.Consensus.Evaluators.AdvisoryLLM
               })
    end

    test "validates action metadata" do
      assert Council.Consult.name() == "council_consult"
      assert Council.Consult.category() == "council"
      assert "council" in Council.Consult.tags()
      assert "advisory" in Council.Consult.tags()
      assert "consult" in Council.Consult.tags()
    end

    test "generates tool schema" do
      tool = Council.Consult.to_tool()
      assert is_map(tool)
      assert tool[:name] == "council_consult"
      assert tool[:description] =~ "Query all advisory council perspectives"
    end

    test "declares taint roles" do
      roles = Council.Consult.taint_roles()
      assert roles[:question] == :control
      assert roles[:context] == :data
      assert roles[:timeout] == :data
      assert roles[:evaluator] == :control
    end
  end

  describe "ConsultOne" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Council.ConsultOne.validate_params(%{})
      assert {:error, _} = Council.ConsultOne.validate_params(%{question: "Test"})

      # Test that schema accepts valid params
      assert {:ok, _} =
               Council.ConsultOne.validate_params(%{
                 question: "Is this design secure?",
                 perspective: :security
               })

      # Test with all optional params
      assert {:ok, _} =
               Council.ConsultOne.validate_params(%{
                 question: "Is this design secure?",
                 perspective: :security,
                 context: %{code: "def foo, do: :bar"},
                 timeout: 60_000,
                 evaluator: Arbor.Consensus.Evaluators.AdvisoryLLM
               })
    end

    test "validates action metadata" do
      assert Council.ConsultOne.name() == "council_consult_one"
      assert Council.ConsultOne.category() == "council"
      assert "council" in Council.ConsultOne.tags()
      assert "single" in Council.ConsultOne.tags()
    end

    test "generates tool schema" do
      tool = Council.ConsultOne.to_tool()
      assert is_map(tool)
      assert tool[:name] == "council_consult_one"
      assert tool[:description] =~ "Query a single advisory council perspective"
    end

    test "declares taint roles" do
      roles = Council.ConsultOne.taint_roles()
      assert roles[:question] == :control
      assert roles[:perspective] == :control
      assert roles[:context] == :data
      assert roles[:timeout] == :data
      assert roles[:evaluator] == :control
    end
  end

  describe "normalize_perspective/1" do
    test "passes through atoms unchanged" do
      assert Council.normalize_perspective(:security) == :security
      assert Council.normalize_perspective(:brainstorming) == :brainstorming
    end

    test "converts valid string perspectives to atoms" do
      assert Council.normalize_perspective("security") == :security
      assert Council.normalize_perspective("stability") == :stability
    end

    test "rejects invalid string perspectives" do
      assert {:error, {:invalid_perspective, "invalid", _allowed}} =
               Council.normalize_perspective("invalid")
    end

    test "rejects non-string/non-atom input" do
      assert {:error, {:invalid_perspective_type, 123}} =
               Council.normalize_perspective(123)
    end
  end

  describe "module structure" do
    test "modules compile and are usable" do
      assert Code.ensure_loaded?(Council.Consult)
      assert Code.ensure_loaded?(Council.ConsultOne)

      assert function_exported?(Council.Consult, :run, 2)
      assert function_exported?(Council.ConsultOne, :run, 2)
      assert function_exported?(Council.Consult, :taint_roles, 0)
      assert function_exported?(Council.ConsultOne, :taint_roles, 0)
    end
  end

  describe "action registration" do
    test "actions are registered in list_actions/0" do
      actions = Arbor.Actions.list_actions()
      assert :council in Map.keys(actions)
      assert Council.Consult in actions[:council]
      assert Council.ConsultOne in actions[:council]
    end

    test "actions appear in all_actions/0" do
      all = Arbor.Actions.all_actions()
      assert Council.Consult in all
      assert Council.ConsultOne in all
    end
  end

  # Integration tests with mocked Consult API
  # These would make real LLM calls - skip by default
  describe "Consult integration" do
    @describetag :llm

    @tag :skip
    test "consults all perspectives with real provider" do
      # This would make real API calls across multiple providers
      assert {:ok, result} =
               Council.Consult.run(
                 %{
                   question: "Should we use Redis or ETS?",
                   context: %{constraints: "must survive restarts"}
                 },
                 %{}
               )

      assert is_list(result.responses)
      assert result.perspective_count == 12
      assert result.response_count > 0
      assert is_integer(result.duration_ms)
    end
  end

  describe "ConsultOne integration" do
    @describetag :llm

    @tag :skip
    test "consults single perspective with real provider" do
      # This would make a real API call
      assert {:ok, result} =
               Council.ConsultOne.run(
                 %{
                   question: "Is this caching approach secure?",
                   perspective: :security,
                   context: %{code: "defmodule Cache do ... end"}
                 },
                 %{}
               )

      assert result.perspective == :security
      assert is_map(result.evaluation)
      assert is_binary(result.reasoning)
      assert is_integer(result.duration_ms)
    end
  end
end
