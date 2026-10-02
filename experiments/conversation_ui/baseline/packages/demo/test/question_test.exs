defmodule ConversationDemo.QuestionTest do
  use ExUnit.Case, async: true
  alias ConversationDemo.Question
  @moduletag :fast

  def data(revision \\ 1),
    do: %{
      "id" => "destination",
      "revision" => revision,
      "prompt" => "Which route should we inspect?",
      "options" => [
        %{"id" => "web", "label" => "Web"},
        %{"id" => "terminal", "label" => "Terminal"},
        %{"id" => "voice", "label" => "Voice"}
      ]
    }

  def message(revision \\ 1, id \\ "question-source"),
    do: %{
      "id" => id,
      "role" => "assistant",
      "ordinal" => revision,
      "text" => Question.encode_question(data(revision))
    }

  def snapshot(messages, deliveries \\ [], pending \\ nil),
    do: %{
      private_cleared: false,
      pending_id: pending,
      projection: %{"messages" => messages, "deliveries" => deliveries}
    }

  test "only bounded assistant transcript questions become interactive" do
    assert Question.decode(message()).id == "destination"
    refute Question.decode(Map.put(message(), "role", "user"))
    refute Question.decode(Map.put(message(), "text", "@conversation-question/v1 invalid"))

    for invalid <- [
          Map.put(data(), "extra", true),
          Map.put(data(), "revision", 0),
          Map.put(data(), "options", Enum.take(data()["options"], 2)),
          Map.put(data(), "options", List.duplicate(hd(data()["options"]), 3))
        ] do
      refute Question.decode(Map.put(message(), "text", Question.encode_question(invalid)))
    end
  end

  test "a choice remains local until host admission and canonical answer ordering is stable" do
    question = Question.sync(nil, snapshot([message()]))
    params = Map.put(Question.params(question), "option_id", "terminal")
    selected = Question.choose(question, params, true)
    assert selected.status == "pending"
    assert {:ok, submitting, text} = Question.confirm(selected, Question.params(selected), true)
    assert submitting.status == "submitting"

    assert text ==
             "@conversation-answer/v1 {\"question_id\":\"destination\",\"revision\":1,\"option_id\":\"terminal\"}"

    assert Question.answer(text)["option_id"] == "terminal"

    refute Question.answer(
             "@conversation-answer/v1 {\"revision\":1,\"question_id\":\"destination\",\"option_id\":\"terminal\"}"
           )
  end

  test "stale question identity, revision and source cannot confirm" do
    question = Question.decode(message())
    selected = %{question | selected: "web"}

    for stale <- [
          Map.put(Question.params(selected), "revision", 2),
          Map.put(Question.params(selected), "source_message_id", "another"),
          Map.put(Question.params(selected), "question_id", "another")
        ] do
      assert {:error, :question_not_actionable} = Question.confirm(selected, stale, true)
      assert Question.choose(question, Map.put(stale, "option_id", "web"), true) == question
    end

    assert {:error, :question_not_actionable} =
             Question.confirm(selected, Question.params(selected), false)
  end

  test "replacement question discards previous selected option" do
    question = %{Question.decode(message()) | selected: "web"}
    newer = Question.sync(question, snapshot([message(), message(2, "question-source-2")]))
    assert newer.revision == 2
    assert newer.selected == nil
  end

  test "only matching host delivery establishes accepted and completed status" do
    question = %{Question.decode(message()) | selected: "voice", status: "submitting"}
    text = Question.encode_answer(question)
    delivery = %{"id" => "answer-delivery", "input_text" => text, "status" => "admitted"}
    accepted = Question.sync(question, snapshot([message()], [delivery]))
    assert accepted.status == "accepted"
    assert accepted.command_id == "answer-delivery"

    completed =
      Question.sync(accepted, snapshot([message()], [%{delivery | "status" => "completed"}]))

    assert completed.status == "completed"

    assert Question.confirm(completed, Question.params(completed), true) ==
             {:error, :question_not_actionable}
  end

  test "reply loss remains uncertain and keeps the saved request identity" do
    question = %{Question.decode(message()) | selected: "web", status: "submitting"}
    uncertain = Question.sync(question, snapshot([message()], [], "saved-answer"))
    assert uncertain.status == "uncertain"
    assert uncertain.command_id == "saved-answer"

    assert {:error, :question_not_actionable} =
             Question.confirm(uncertain, Question.params(uncertain), true)
  end

  test "access loss clears local selection and question content" do
    question = %{Question.decode(message()) | selected: "web"}
    assert Question.sync(question, %{snapshot([message()]) | private_cleared: true}) == nil
  end

  test "reissuing a question ID and revision in a new source does not inherit an older answer" do
    old = %{Question.decode(message()) | selected: "web", status: "submitting"}
    text = Question.encode_answer(old)
    delivery = %{"id" => "old-delivery", "input_text" => text, "status" => "completed"}
    user = %{"id" => "old-answer", "role" => "user", "text" => text, "ordinal" => 2}
    answered = Question.sync(old, snapshot([message(), user], [delivery]))
    assert answered.status == "completed"
    replacement = %{message(1, "new-source") | "ordinal" => 3}
    current = Question.sync(answered, snapshot([message(), user, replacement], [delivery]))
    assert current.source_message_id == "new-source"
    assert current.status == "pending"
    assert current.selected == nil
  end

  test "a three-way keyboard cycle is reversible and refuses blocked mutation" do
    question = Question.decode(message())
    assert Question.cycle(question, false) == question
    assert Question.cycle(question, true).selected == "web"

    assert question
           |> Question.cycle(true)
           |> Question.cycle(true)
           |> Question.cycle(true)
           |> Question.cycle(true)
           |> Map.fetch!(:selected) == "web"
  end
end
