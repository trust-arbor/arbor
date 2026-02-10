defmodule Arbor.Orchestrator.Conformance1110Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Transforms.ModelStylesheet

  test "11.10 parses stylesheet from graph attribute and applies selectors" do
    dot = """
    digraph Flow {
      model_stylesheet="
        * { llm_provider: anthropic; reasoning_effort: low; }
        box { llm_model: shape-model; }
        .code { llm_model: class-model; }
        #critical { llm_model: id-model; reasoning_effort: high; }
      "
      start [shape=Mdiamond]
      plain_box [shape=box]
      class_box [shape=box, class="code"]
      critical [shape=box, class="code"]
      exit [shape=Msquare]
      start -> plain_box -> class_box -> critical -> exit
    }
    """

    assert {:ok, graph} = Arbor.Orchestrator.parse(dot)
    transformed = ModelStylesheet.apply(graph)

    assert transformed.nodes["plain_box"].attrs["llm_model"] == "shape-model"
    assert transformed.nodes["plain_box"].attrs["llm_provider"] == "anthropic"
    assert transformed.nodes["class_box"].attrs["llm_model"] == "class-model"
    assert transformed.nodes["critical"].attrs["llm_model"] == "id-model"
    assert transformed.nodes["critical"].attrs["reasoning_effort"] == "high"
  end

  test "11.10 specificity order and equal-specificity rule order are respected" do
    dot = """
    digraph Flow {
      model_stylesheet="
        * { llm_provider: anthropic; llm_model: universal-model; }
        box { llm_model: shape-model; }
        .code { llm_model: class-early; }
        .code { llm_model: class-late; llm_provider: openai; }
        #critical { llm_model: id-model; }
      "
      start [shape=Mdiamond]
      class_box [shape=box, class="code"]
      critical [shape=box, class="code"]
      exit [shape=Msquare]
      start -> class_box -> critical -> exit
    }
    """

    assert {:ok, graph} = Arbor.Orchestrator.parse(dot)
    transformed = ModelStylesheet.apply(graph)

    # Later .code rule overrides earlier .code rule, and class beats shape/universal.
    assert transformed.nodes["class_box"].attrs["llm_model"] == "class-late"
    assert transformed.nodes["class_box"].attrs["llm_provider"] == "openai"

    # ID selector has highest priority.
    assert transformed.nodes["critical"].attrs["llm_model"] == "id-model"
  end

  test "11.10 explicit node attributes override stylesheet properties" do
    dot = """
    digraph Flow {
      model_stylesheet="
        * { llm_provider: anthropic; llm_model: universal-model; reasoning_effort: low; }
        .code { llm_model: class-model; reasoning_effort: medium; }
      "
      start [shape=Mdiamond]
      explicit [shape=box, class="code", llm_model="explicit-model", reasoning_effort="high"]
      exit [shape=Msquare]
      start -> explicit -> exit
    }
    """

    assert {:ok, graph} = Arbor.Orchestrator.parse(dot)
    transformed = ModelStylesheet.apply(graph)

    assert transformed.nodes["explicit"].attrs["llm_model"] == "explicit-model"
    assert transformed.nodes["explicit"].attrs["reasoning_effort"] == "high"
    assert transformed.nodes["explicit"].attrs["llm_provider"] == "anthropic"
  end
end
