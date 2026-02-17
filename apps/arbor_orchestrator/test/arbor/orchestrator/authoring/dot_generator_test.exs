defmodule Arbor.Orchestrator.Authoring.DotGeneratorTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Authoring.{Conversation, DotGenerator}

  @valid_dot """
  digraph Test {
    graph [goal="Test pipeline"]
    start [shape=Mdiamond type="start"]
    work [type="codergen" prompt="Do work"]
    done [shape=Msquare type="exit"]
    start -> work
    work -> done
  }
  """

  describe "generate/2" do
    test "returns :pipeline when response contains PIPELINE_SPEC block" do
      response = "Here is your pipeline:\n<<PIPELINE_SPEC>>\n#{@valid_dot}\n<<END_PIPELINE_SPEC>>"
      backend = fn _prompt -> {:ok, response} end
      conv = Conversation.new(:blank, system_prompt: "test")

      assert {:pipeline, dot, updated_conv} = DotGenerator.generate(conv, backend)
      assert dot =~ "digraph Test"
      assert Conversation.turn_count(updated_conv) == 1
    end

    test "returns :question when response has no pipeline" do
      backend = fn _prompt -> {:ok, "What kind of pipeline do you want?"} end
      conv = Conversation.new(:blank, system_prompt: "test")

      assert {:question, text, updated_conv} = DotGenerator.generate(conv, backend)
      assert text =~ "What kind"
      assert Conversation.turn_count(updated_conv) == 1
    end

    test "returns :error when backend fails" do
      backend = fn _prompt -> {:error, :timeout} end
      conv = Conversation.new(:blank, system_prompt: "test")

      assert {:error, :timeout} = DotGenerator.generate(conv, backend)
    end

    test "extracts DOT from markdown code fence" do
      response = "```dot\n#{@valid_dot}\n```"
      backend = fn _prompt -> {:ok, response} end
      conv = Conversation.new(:blank, system_prompt: "test")

      assert {:pipeline, dot, _conv} = DotGenerator.generate(conv, backend)
      assert dot =~ "digraph Test"
    end

    test "extracts DOT from graphviz code fence" do
      response = "```graphviz\n#{@valid_dot}\n```"
      backend = fn _prompt -> {:ok, response} end
      conv = Conversation.new(:blank, system_prompt: "test")

      assert {:pipeline, dot, _conv} = DotGenerator.generate(conv, backend)
      assert dot =~ "digraph Test"
    end
  end

  describe "validate_and_fix/3" do
    test "returns :ok for a valid pipeline" do
      backend = fn _prompt -> {:ok, "unused"} end
      conv = Conversation.new(:blank, system_prompt: "test")

      assert {:ok, dot, graph} = DotGenerator.validate_and_fix(@valid_dot, conv, backend)
      assert dot == @valid_dot
      assert map_size(graph.nodes) == 3
    end

    test "attempts to fix invalid DOT via LLM" do
      invalid_dot = "digraph { broken }"
      fix_call_count = :counters.new(1, [:atomics])

      backend = fn _prompt ->
        :counters.add(fix_call_count, 1, 1)

        {:ok,
         "<<PIPELINE_SPEC>>\n#{@valid_dot}\n<<END_PIPELINE_SPEC>>"}
      end

      conv = Conversation.new(:blank, system_prompt: "test")

      assert {:ok, _dot, _graph} = DotGenerator.validate_and_fix(invalid_dot, conv, backend)
      # Backend was called at least once for the fix
      assert :counters.get(fix_call_count, 1) >= 1
    end

    test "returns error after max fix attempts" do
      always_broken = fn _prompt ->
        {:ok, "<<PIPELINE_SPEC>>\ndigraph { broken }\n<<END_PIPELINE_SPEC>>"}
      end

      conv = Conversation.new(:blank, system_prompt: "test")

      assert {:error, msg} = DotGenerator.validate_and_fix("bad", conv, always_broken)
      assert msg =~ "Failed" or msg =~ "parse error" or msg =~ "question"
    end

    test "returns error when LLM asks question instead of fixing" do
      backend = fn _prompt -> {:ok, "I don't understand the error"} end
      conv = Conversation.new(:blank, system_prompt: "test")

      assert {:error, msg} = DotGenerator.validate_and_fix("bad", conv, backend)
      assert msg =~ "question" or msg =~ "Failed"
    end
  end

  describe "extract_pipeline/1" do
    test "extracts from PIPELINE_SPEC markers" do
      response = "Text before\n<<PIPELINE_SPEC>>\ndigraph X {}\n<<END_PIPELINE_SPEC>>\nText after"
      assert {:ok, "digraph X {}"} = DotGenerator.extract_pipeline(response)
    end

    test "extracts from dot code fence" do
      response = "```dot\ndigraph Y {}\n```"
      assert {:ok, "digraph Y {}"} = DotGenerator.extract_pipeline(response)
    end

    test "returns :none when no pipeline found" do
      assert :none = DotGenerator.extract_pipeline("Just a regular response")
    end

    test "returns :none for non-digraph code fence" do
      response = "```elixir\ndefmodule Foo do end\n```"
      assert :none = DotGenerator.extract_pipeline(response)
    end

    test "handles empty markers" do
      response = "<<PIPELINE_SPEC>>\n\n<<END_PIPELINE_SPEC>>"
      assert {:ok, ""} = DotGenerator.extract_pipeline(response)
    end
  end
end
