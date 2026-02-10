defmodule Arbor.Orchestrator.HumanTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Human.{Question, RecordingInterviewer}

  test "recording interviewer delegates and records" do
    parent = self()

    question = %Question{
      text: "Pick one",
      stage: "gate",
      options: [
        %{key: "Y", label: "Yes", to: "yes_path"},
        %{key: "N", label: "No", to: "no_path"}
      ]
    }

    answer =
      RecordingInterviewer.ask(question,
        inner: {Arbor.Orchestrator.Human.QueueInterviewer, [answers: ["N"]]},
        recorder: fn q, a -> send(parent, {:recorded, q.stage, a.value}) end
      )

    assert answer.value == "N"
    assert_receive {:recorded, "gate", "N"}
  end
end
