defmodule ConversationKit.ControlsTest do
  use ExUnit.Case, async: true

  alias ConversationKit.Controls

  test "replacement is disposable, projection keeps delivery and execution distinct and never speaks" do
    snapshot = snapshot(activity("uncertain", "not_observed", "requested"))
    assert {:ok, ^snapshot} = Controls.replace(%{"old_secret" => "discard me"}, snapshot)
    assert {:ok, display} = Controls.project(snapshot)
    assert display["speech"] == []
    [block] = display["activities"]
    assert block["delivery_text"] == "Delivery outcome uncertain"
    assert block["execution_text"] == "Execution not observed"
    assert block["cancellation_text"] == "Cancellation requested; termination unconfirmed"
    refute block["cancel_actionable"]
    refute Map.has_key?(display, "old_secret")
    assert Controls.new() == %{"activities" => [], "interactions" => []}
  end

  test "cancel describes a request for each pending delivery even without observed execution" do
    for delivery <- ~w(admitted dispatch_started uncertain) do
      snapshot = snapshot(activity(delivery, "not_observed", "none"))
      action = %{"kind" => "cancel", "command_id" => "command_1"}
      expected = %{"name" => "conversation.cancel", "input" => %{"command_id" => "command_1"}}
      assert {:ok, ^expected} = Controls.intent(snapshot, action)
      assert {:ok, ^expected} = Controls.intent(snapshot, action)
      assert {:ok, ^snapshot} = Controls.replace(Controls.new(), snapshot)
    end

    for {delivery, cancellation} <- [
          {"completed", "none"},
          {"uncertain", "requested"},
          {"admitted", "confirmed"}
        ] do
      assert {:error, :not_actionable} =
               Controls.intent(snapshot(activity(delivery, "running", cancellation)), %{
                 "kind" => "cancel",
                 "command_id" => "command_1"
               })
    end
  end

  test "choice identifies the exact pending operation and allows duplicate labels" do
    prompt = choice()
    snapshot = snapshot(activity(), [prompt])
    action = choose("choice_2")

    assert {:ok, %{"name" => "interaction.choose", "input" => input}} =
             Controls.intent(snapshot, action)

    assert input == Map.delete(action, "kind")
    assert {:ok, display} = Controls.project(snapshot)
    assert hd(display["interactions"])["actionable"]
    refute hd(display["interactions"])["protected"]

    for {key, value} <- [
          {"command_id", "foreign"},
          {"request_id", "stale"},
          {"operation_id", "stale"},
          {"revision", 2},
          {"choice_id", "Same label"}
        ] do
      assert {:error, :not_actionable} = Controls.intent(snapshot, Map.put(action, key, value))
    end
  end

  test "terminal prompt, completed command and cancellation disable answers without inventing resolutions" do
    for status <- ~w(responded expired abandoned retired cancelled) do
      snapshot = snapshot(activity(), [Map.put(choice(), "status", status)])
      assert {:error, :not_actionable} = Controls.intent(snapshot, choose("choice_1"))
      assert {:ok, display} = Controls.project(snapshot)
      refute hd(display["interactions"])["actionable"]
      assert hd(display["interactions"])["status"] == status
    end

    for activity <- [
          activity("completed"),
          activity("uncertain", "running", "requested"),
          activity("admitted", "not_observed", "confirmed")
        ] do
      snapshot = snapshot(activity, [choice()])
      assert {:error, :not_actionable} = Controls.intent(snapshot, choose("choice_1"))
      assert {:ok, display} = Controls.project(snapshot)
      assert hd(display["interactions"])["status"] == "pending"
      refute hd(display["interactions"])["actionable"]
    end
  end

  test "protected approval cannot be answered through ordinary choice" do
    approval = choice() |> Map.put("kind", "approval") |> Map.put("choices", [])
    snapshot = snapshot(activity(), [approval])
    assert {:ok, display} = Controls.project(snapshot)
    assert hd(display["interactions"])["protected"]
    assert display["speech"] == []
    assert {:error, :not_actionable} = Controls.intent(snapshot, choose("choice_1"))

    action =
      choose("choice_1")
      |> Map.delete("choice_id")
      |> Map.merge(%{"kind" => "approve", "decision" => "approved", "note" => "Reviewed 東京"})

    assert {:ok, %{"name" => "approval.answer", "input" => input}} =
             Controls.intent(snapshot, action)

    assert input == Map.delete(action, "kind")

    assert {:error, :not_actionable} =
             Controls.intent(snapshot, Map.put(action, "decision", "approve"))

    assert {:error, :not_actionable} =
             Controls.intent(snapshot, Map.put(action, "note", String.duplicate("x", 4097)))

    assert {:error, :not_actionable} = Controls.intent(snapshot(activity(), [choice()]), action)
  end

  test "request rework is an exact protected intent and preserves the review note" do
    approval = choice() |> Map.put("kind", "approval") |> Map.put("choices", [])
    snapshot = snapshot(activity(), [approval])

    action =
      choose("choice_1")
      |> Map.delete("choice_id")
      |> Map.merge(%{"kind" => "approve", "decision" => "rework", "note" => "Revise 東京 🌲"})

    assert {:ok, %{"name" => "approval.answer", "input" => input}} =
             Controls.intent(snapshot, action)

    assert input == Map.delete(action, "kind")
    assert {:ok, display} = Controls.project(snapshot)
    assert hd(display["interactions"])["status"] == "pending"
    assert display["speech"] == []

    for changed <- [
          Map.put(action, "revision", 2),
          Map.put(action, "request_id", "stale"),
          Map.put(action, "command_id", "foreign"),
          Map.put(action, "decision", "reworked"),
          Map.put(action, "proof", "forged"),
          Map.put(action, "note", <<255>>)
        ] do
      assert {:error, :not_actionable} = Controls.intent(snapshot, changed)
    end

    assert {:error, :not_actionable} = Controls.intent(snapshot(activity(), [choice()]), action)
  end

  test "foreign command prompt is passive and cannot create local authority" do
    prompt = Map.put(choice(), "command_id", "foreign")
    snapshot = snapshot(activity(), [prompt])
    assert {:ok, display} = Controls.project(snapshot)
    refute hd(display["interactions"])["actionable"]

    assert {:error, :not_actionable} =
             Controls.intent(snapshot, Map.put(choose("choice_1"), "command_id", "foreign"))
  end

  test "closed observations reject host tasks, source handles, proofs, callbacks and atom keys" do
    valid = snapshot(activity(), [choice()])

    for value <- [
          Map.put(valid, "task_id", "secret"),
          Map.put(valid, :activities, []),
          %{"activities" => [%{activity() | "command_id" => <<255>>}], "interactions" => []}
        ] do
      assert {:error, :invalid_snapshot} = Controls.replace(Controls.new(), value)
      assert {:error, :invalid_snapshot} = Controls.project(value)
      assert {:error, :invalid_snapshot} = Controls.intent(value, choose("choice_1"))
    end

    for {key, value} <- [
          {"task_id", "secret"},
          {"source_id", "secret"},
          {"proof", "secret"},
          {"callback", fn -> :effect end},
          {"session_pid", self()}
        ] do
      assert {:error, :invalid_snapshot} =
               Controls.replace(Controls.new(), snapshot(Map.put(activity(), key, value)))

      assert {:error, :invalid_snapshot} =
               Controls.replace(
                 Controls.new(),
                 snapshot(activity(), [Map.put(choice(), key, value)])
               )
    end

    assert {:error, :not_actionable} =
             Controls.intent(valid, Map.put(choose("choice_1"), "proof", "secret"))

    assert {:error, :invalid_action} =
             Controls.intent(valid, %{kind: "cancel", command_id: "command_1"})
  end

  test "list, individual UTF8 and total encoded byte bounds are enforced" do
    assert {:error, :invalid_snapshot} =
             Controls.replace(Controls.new(), %{
               "activities" =>
                 Enum.map(1..51, &Map.put(activity(), "command_id", "command_#{&1}")),
               "interactions" => []
             })

    assert {:error, :invalid_snapshot} =
             Controls.replace(
               Controls.new(),
               snapshot(Map.put(activity(), "preview", String.duplicate("👋", 8193)))
             )

    assert {:ok, _} =
             Controls.replace(
               Controls.new(),
               snapshot(Map.put(activity(), "preview", String.duplicate("👋", 8192)))
             )

    assert {:error, :invalid_snapshot} =
             Controls.replace(
               Controls.new(),
               snapshot(activity(), [Map.put(choice(), "text", String.duplicate("x", 4097))])
             )

    too_large = %{
      "activities" =>
        Enum.map(1..9, fn n ->
          activity()
          |> Map.put("command_id", "command_#{n}")
          |> Map.put("preview", String.duplicate("x", 32768))
        end),
      "interactions" => []
    }

    assert {:error, :invalid_snapshot} = Controls.replace(Controls.new(), too_large)
  end

  test "duplicate operation identities and choice IDs reject rather than guess" do
    assert {:error, :invalid_snapshot} =
             Controls.replace(Controls.new(), %{
               "activities" => [activity(), activity()],
               "interactions" => []
             })

    assert {:error, :invalid_snapshot} =
             Controls.replace(Controls.new(), snapshot(activity(), [choice(), choice()]))

    duplicate =
      Map.put(choice(), "choices", [
        %{"id" => "same", "label" => "A"},
        %{"id" => "same", "label" => "B"}
      ])

    assert {:error, :invalid_snapshot} =
             Controls.replace(Controls.new(), snapshot(activity(), [duplicate]))

    assert {:error, :invalid_snapshot} =
             Controls.replace(
               Controls.new(),
               snapshot(activity(), [
                 Map.put(
                   choice(),
                   "choices",
                   Enum.map(1..33, &%{"id" => "choice_#{&1}", "label" => "A"})
                 )
               ])
             )
  end

  test "progress is closed display data and never an execution outcome" do
    for type <-
          ~w(pipeline_started pipeline_completed pipeline_failed stage_started stage_completed stage_failed stage_retrying) do
      observed =
        activity("uncertain", "not_observed")
        |> Map.put("progress", %{"type" => type, "node_id" => "compute.response"})

      assert {:ok, display} = Controls.project(snapshot(observed))
      assert hd(display["activities"])["execution"] == "not_observed"
      assert hd(display["activities"])["delivery_status"] == "uncertain"
    end

    assert {:error, :invalid_snapshot} =
             Controls.replace(
               Controls.new(),
               snapshot(Map.put(activity(), "progress", %{"type" => "stopped", "node_id" => nil}))
             )
  end

  defp activity(delivery \\ "dispatch_started", execution \\ "running", cancellation \\ "none") do
    %{
      "command_id" => "command_1",
      "delivery_status" => delivery,
      "execution" => execution,
      "cancellation" => %{"status" => cancellation},
      "preview" => "Hello 東京 👋",
      "preview_truncated" => false,
      "progress" => nil
    }
  end

  defp choice do
    %{
      "command_id" => "command_1",
      "request_id" => "request_1",
      "operation_id" => "operation_1",
      "revision" => 1,
      "kind" => "choice",
      "status" => "pending",
      "text" => "Choose one",
      "choices" => [
        %{"id" => "choice_1", "label" => "Same label"},
        %{"id" => "choice_2", "label" => "Same label"}
      ]
    }
  end

  defp choose(id) do
    choice()
    |> Map.take(~w(command_id request_id operation_id revision))
    |> Map.merge(%{"kind" => "choose", "choice_id" => id})
  end

  defp snapshot(activity, interactions \\ []),
    do: %{"activities" => [activity], "interactions" => interactions}
end
