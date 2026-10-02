Code.require_file("comparison_fixture.exs", __DIR__)

defmodule ConversationDemo.ComparisonInterfacesTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias ConversationDemo.{ArborBreezeView, ArborInteraction, ComparisonFixtureFacade, Question}
  @endpoint ConversationDemo.Endpoint
  @moduletag :fast

  setup do
    start_supervised!(%{
      id: ComparisonFixtureFacade,
      start:
        {Agent, :start_link,
         [fn -> ComparisonFixtureFacade.initial() end, [name: ComparisonFixtureFacade]]}
    })

    old = Application.fetch_env(:conversation_demo, :arbor_client_options)

    opts = [
      caller: "human-fixture",
      target: "agent-fixture",
      proof_provider: &ComparisonFixtureFacade.proof/1,
      adapter_options: [facade: ComparisonFixtureFacade, page_limit: 100, max_pages: 100]
    ]

    Application.put_env(:conversation_demo, :arbor_client_options, opts)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:conversation_demo, :arbor_client_options, value)
        :error -> Application.delete_env(:conversation_demo, :arbor_client_options)
      end
    end)

    {:ok, opts: opts}
  end

  defp question_entry(revision \\ 1) do
    data = %{
      "id" => "destination",
      "revision" => revision,
      "prompt" => "Which route should we inspect?",
      "options" => [
        %{"id" => "web", "label" => "Web"},
        %{"id" => "terminal", "label" => "Terminal"},
        %{"id" => "voice", "label" => "Voice"}
      ]
    }

    %{
      id: "question-source-#{revision}",
      role: "assistant",
      content: Question.encode_question(data),
      timestamp: "2026-10-01T00:00:00Z",
      entry_ordinal: revision
    }
  end

  test "LiveView and Breeze select locally, confirm one admitted answer and share its status" do
    ComparisonFixtureFacade.seed([question_entry()])
    {:ok, web, _} = live(build_conn(), "/arbor")
    terminal = Breeze.Test.start!(ArborBreezeView, size: {110, 55})
    on_exit(fn -> Breeze.Test.stop(terminal) end)
    assert has_element?(web, "#question-confirm[disabled]")
    web |> element("#question-option-terminal") |> render_click()
    assert has_element?(web, "#question-option-terminal[aria-pressed='true']")
    assert ComparisonFixtureFacade.state().commands == %{}
    web |> element("#question-confirm") |> render_click()
    assert has_element?(web, "#question-status", "accepted")
    assert [command] = Map.values(ComparisonFixtureFacade.state().commands)

    assert command.text ==
             "@conversation-answer/v1 {\"question_id\":\"destination\",\"revision\":1,\"option_id\":\"terminal\"}"

    Breeze.Test.event(terminal, "chat:refresh", %{})
    assert Breeze.Test.render_text!(terminal) =~ "[accepted]"
    assert Breeze.Test.render_text!(terminal) =~ "● Terminal"
    Breeze.Test.input(terminal, "F8")
    assert map_size(ComparisonFixtureFacade.state().commands) == 1
  end

  test "Breeze uses actual keyboard events for a three-way question and preserves ordinary draft" do
    ComparisonFixtureFacade.seed([question_entry()])
    terminal = Breeze.Test.start!(ArborBreezeView, size: {110, 55})
    on_exit(fn -> Breeze.Test.stop(terminal) end)
    Breeze.Test.event(terminal, "chat:draft", %{value: "draft café 東京 🌿"})
    Breeze.Test.input(terminal, "F7")
    Breeze.Test.input(terminal, "F7")
    assert ComparisonFixtureFacade.state().commands == %{}
    Breeze.Test.input(terminal, "F8")
    assert [command] = Map.values(ComparisonFixtureFacade.state().commands)
    assert Question.answer(command.text)["option_id"] == "terminal"
    rendered = Breeze.Test.render_text!(terminal)
    assert rendered =~ "draft café 東京 🌿"
    assert rendered =~ "[accepted]"
  end

  test "both renderer history controls bound rows while full history remains available" do
    entries =
      for n <- 1..100,
          do: %{
            id: "record-#{n}",
            role: "user",
            content: "Record #{n}.",
            timestamp: "2026-10-01T00:00:00Z",
            entry_ordinal: n
          }

    ComparisonFixtureFacade.seed(entries)
    {:ok, web, _} = live(build_conn(), "/arbor")

    assert length(
             web
             |> element("#transcript")
             |> render()
             |> String.split("data-kind=\"message\"")
           ) - 1 == 20

    refute has_element?(web, "#arbor-block-message-record-1")
    web |> element("#history-older") |> render_click()
    assert has_element?(web, "#arbor-block-message-record-61")
    web |> element("#history-toggle") |> render_click()
    assert has_element?(web, "#arbor-block-message-record-1")
    web |> element("#history-toggle") |> render_click()
    assert has_element?(web, "#arbor-block-message-record-61")
    terminal = Breeze.Test.start!(ArborBreezeView, size: {110, 55})
    on_exit(fn -> Breeze.Test.stop(terminal) end)
    assert Breeze.Test.render_text!(terminal) =~ "Messages 81–100 of 100"
    Breeze.Test.input(terminal, "F9")
    assert Breeze.Test.render_text!(terminal) =~ "Messages 61–80 of 100"
    Breeze.Test.input(terminal, "F10")
    assert Breeze.Test.render_text!(terminal) =~ "Messages 81–100 of 100"
    Breeze.Test.input(terminal, "F11")
    assert Breeze.Test.render_text!(terminal) =~ "Messages 1–100 of 100"
  end

  test "reply loss keeps question answer unknown until saved host ID is checked" do
    ComparisonFixtureFacade.seed([question_entry()])
    ui = ArborInteraction.new()
    ui = ArborInteraction.act(ui, "question:cycle", %{})
    ComparisonFixtureFacade.mode(:ambiguous_saved)
    unknown = ArborInteraction.act(ui, "question:confirm", Question.params(ui.question))
    assert unknown.question.status == "uncertain"
    saved = unknown.snapshot.pending_id
    assert saved
    retried = ArborInteraction.act(unknown, "retry", %{})
    assert retried.question.status == "accepted"
    assert retried.question.command_id == saved
    assert map_size(ComparisonFixtureFacade.state().commands) == 1
  end

  test "access denial clears question and selection from both visual surfaces" do
    ComparisonFixtureFacade.seed([question_entry()])
    {:ok, web, _} = live(build_conn(), "/arbor")
    terminal = Breeze.Test.start!(ArborBreezeView, size: {110, 55})
    on_exit(fn -> Breeze.Test.stop(terminal) end)
    web |> element("#question-option-voice") |> render_click()
    Breeze.Test.input(terminal, "F7")
    ComparisonFixtureFacade.mode(:denied)
    web |> element("#refresh") |> render_click()
    Breeze.Test.input(terminal, "F3")
    refute has_element?(web, "#structured-question")
    refute Breeze.Test.render_text!(terminal) =~ "Which route should we inspect?"
    assert ComparisonFixtureFacade.state().commands == %{}
  end
end
