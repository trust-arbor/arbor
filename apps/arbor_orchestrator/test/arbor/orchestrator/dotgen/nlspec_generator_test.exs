defmodule Arbor.Orchestrator.Dotgen.NLSpecGeneratorTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Dotgen.NLSpecGenerator

  @sample_file_info %{
    path: "lib/example/counter.ex",
    module: "Example.Counter",
    moduledoc: "A simple counter module.",
    behaviours: ["GenServer"],
    callbacks: ["init/1", "handle_call/3"],
    struct_fields: [{:count, "0"}, {:name, "nil"}],
    types: ["@type t :: %__MODULE__{}"],
    public_functions: [
      %{
        name: :increment,
        arity: 1,
        spec: "@spec increment(t()) :: t()",
        doc: "Increment the counter by 1.",
        body_summary: "Updates count field",
        clauses: [%{patterns: ["%{count: n}"], guard: nil, body_summary: "%{count: n + 1}"}],
        case_branches: []
      },
      %{
        name: :get,
        arity: 1,
        spec: "@spec get(t()) :: integer()",
        doc: "Get the current count.",
        body_summary: "Returns count",
        clauses: [],
        case_branches: []
      }
    ],
    private_functions: [
      %{name: :validate, arity: 1, body_summary: "Checks count >= 0"}
    ],
    module_attributes: [
      %{name: :default_count, value: "0"}
    ],
    aliases: ["Arbor.Common.SafeAtom"],
    uses: ["GenServer"],
    line_count: 45,
    test_examples: nil
  }

  describe "generate_module_spec/2" do
    test "includes module name as header" do
      spec = NLSpecGenerator.generate_module_spec(@sample_file_info)
      assert spec =~ "### Example.Counter"
    end

    test "includes moduledoc as overview" do
      spec = NLSpecGenerator.generate_module_spec(@sample_file_info)
      assert spec =~ "simple counter"
    end

    test "includes struct fields" do
      spec = NLSpecGenerator.generate_module_spec(@sample_file_info)
      assert spec =~ "count"
      assert spec =~ "name"
    end

    test "includes public API" do
      spec = NLSpecGenerator.generate_module_spec(@sample_file_info)
      assert spec =~ "increment"
      assert spec =~ "get"
    end

    test "includes behaviours" do
      spec = NLSpecGenerator.generate_module_spec(@sample_file_info)
      assert spec =~ "GenServer"
    end

    test "excludes private functions by default" do
      spec = NLSpecGenerator.generate_module_spec(@sample_file_info)
      # Private functions may or may not appear in implementation notes
      # but should not be in the public API section
      refute spec =~ "Private API"
    end

    test "includes private functions when requested" do
      spec = NLSpecGenerator.generate_module_spec(@sample_file_info, include_private: true)
      assert spec =~ "validate"
    end
  end

  describe "generate_subsystem_spec/3" do
    test "groups modules under subsystem header" do
      spec = NLSpecGenerator.generate_subsystem_spec("Counters", [@sample_file_info])
      assert spec =~ "## Counters"
      assert spec =~ "Example.Counter"
    end

    test "includes optional goal" do
      spec =
        NLSpecGenerator.generate_subsystem_spec("Counters", [@sample_file_info],
          goal: "Manage counting operations"
        )

      assert spec =~ "Manage counting"
    end

    test "handles multiple modules" do
      other_info = %{@sample_file_info | module: "Example.Timer", moduledoc: "A timer module."}

      spec =
        NLSpecGenerator.generate_subsystem_spec("Time", [@sample_file_info, other_info])

      assert spec =~ "Example.Counter"
      assert spec =~ "Example.Timer"
    end
  end

  describe "generate_module_spec/2 with minimal info" do
    test "handles empty functions list" do
      info = %{@sample_file_info | public_functions: [], private_functions: []}
      spec = NLSpecGenerator.generate_module_spec(info)
      assert spec =~ "Example.Counter"
    end

    test "handles nil moduledoc" do
      info = %{@sample_file_info | moduledoc: nil}
      spec = NLSpecGenerator.generate_module_spec(info)
      assert spec =~ "Example.Counter"
    end

    test "handles empty struct fields" do
      info = %{@sample_file_info | struct_fields: []}
      spec = NLSpecGenerator.generate_module_spec(info)
      assert is_binary(spec)
    end
  end
end
