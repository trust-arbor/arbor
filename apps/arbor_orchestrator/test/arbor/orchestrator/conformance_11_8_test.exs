defmodule Arbor.Orchestrator.Conformance118Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Human.{
    AutoApproveInterviewer,
    CallbackInterviewer,
    ConsoleInterviewer,
    Question,
    QueueInterviewer
  }

  test "11.8 interviewer interface works via wait.human ask(question) -> answer" do
    dot = """
    digraph Flow {
      start [shape=Mdiamond]
      gate [shape=hexagon, label="Proceed?", fan_out="false"]
      yes_path [label="Yes path"]
      no_path [label="No path"]
      exit [shape=Msquare]
      start -> gate
      gate -> yes_path [label="[Y] Yes"]
      gate -> no_path [label="[N] No"]
      yes_path -> exit
      no_path -> exit
    }
    """

    interviewer = fn _question -> %{value: "N"} end
    assert {:ok, result} = Arbor.Orchestrator.run(dot, interviewer: interviewer)
    assert "no_path" in result.completed_nodes
  end

  test "11.8 question model supports single_select, multi_select, free_text, and confirm" do
    assert %Question{type: :single_select}.type == :single_select
    assert %Question{type: :multi_select}.type == :multi_select
    assert %Question{type: :free_text}.type == :free_text
    assert %Question{type: :confirm}.type == :confirm
  end

  test "11.8 auto-approve interviewer selects first option" do
    question = %Question{
      text: "Pick one",
      type: :single_select,
      options: [
        %{key: "Y", label: "Yes", to: "yes_path"},
        %{key: "N", label: "No", to: "no_path"}
      ]
    }

    answer = AutoApproveInterviewer.ask(question, [])
    assert answer.value == "Y"
    assert answer.selected_option.to == "yes_path"
  end

  test "11.8 console interviewer prompts and reads input" do
    parent = self()

    io = %{
      puts: fn line -> send(parent, {:puts, line}) end,
      gets: fn _prompt -> "N\n" end
    }

    question = %Question{
      text: "Pick one",
      type: :single_select,
      options: [
        %{key: "Y", label: "Yes", to: "yes_path"},
        %{key: "N", label: "No", to: "no_path"}
      ]
    }

    answer = ConsoleInterviewer.ask(question, io: io)
    assert answer.value == "N"
    assert answer.selected_option.to == "no_path"
    assert_receive {:puts, "[?] Pick one"}
  end

  test "11.8 callback interviewer delegates to callback" do
    question = %Question{text: "Proceed?", type: :confirm}

    answer =
      CallbackInterviewer.ask(question,
        callback: fn q ->
          assert q.text == "Proceed?"
          %{value: "approved"}
        end
      )

    assert answer.value == "approved"
  end

  test "11.8 queue interviewer reads pre-filled answer queue" do
    question = %Question{text: "Proceed?", stage: "gate", type: :single_select}
    answer = QueueInterviewer.ask(question, answers: ["N"])
    assert answer.value == "N"
  end
end
