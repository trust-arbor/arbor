defmodule ConversationDemo.ArborInteraction do
  @moduledoc "Socket-first presentation state shared by the Arbor web and terminal shells."
  alias ConversationDemo.ArborClient
  alias ConversationDemo.{HistoryWindow, Question}

  def new(opts \\ []) do
    client_options =
      Keyword.get(
        opts,
        :client_options,
        Application.get_env(:conversation_demo, :arbor_client_options, [])
      )

    {:ok, client} = ArborClient.start(client_options)
    snapshot = ArborClient.snapshot(client)

    %{
      client: client,
      snapshot: snapshot,
      draft: "",
      composer_ack: nil,
      question: Question.sync(nil, snapshot),
      window: HistoryWindow.new()
    }
  end

  def act(ui, "history:" <> action, _),
    do: %{ui | window: HistoryWindow.move(ui.window, action, ui.snapshot)}

  def act(ui, "question:choose", params),
    do: %{ui | question: Question.choose(ui.question, params, ui.snapshot.send_allowed)}

  def act(ui, "question:cycle", _),
    do: %{ui | question: Question.cycle(ui.question, ui.snapshot.send_allowed)}

  def act(ui, "question:confirm", params) do
    case Question.confirm(ui.question, params, ui.snapshot.send_allowed) do
      {:ok, question, text} ->
        next = %{ui | question: question}

        case ArborClient.act(ui.client, :send, text) do
          {:ok, snapshot, _ack} -> update(next, snapshot)
          {:ok, snapshot} -> update(next, snapshot)
          {:error, snapshot} -> update(next, snapshot)
        end

      {:error, _} ->
        ui
    end
  end

  def act(ui, "draft", %{"text" => text}) when is_binary(text),
    do: %{ui | draft: text, composer_ack: nil}

  def act(ui, "send", params) do
    text = Map.get(params, "text", ui.draft)

    case ArborClient.act(ui.client, :send, text) do
      {:ok, snapshot, ack} -> acknowledge(ui, snapshot, ack)
      {:ok, snapshot} -> update(ui, snapshot)
      {:error, snapshot} -> update(ui, snapshot)
    end
  end

  def act(ui, action, _) when action in ["refresh", "reconnect", "disconnect", "retry"] do
    op =
      case action do
        "refresh" -> :refresh
        "reconnect" -> :reconnect
        "disconnect" -> :disconnect
        "retry" -> :retry
      end

    case ArborClient.act(ui.client, op) do
      {:ok, snapshot, ack} ->
        acknowledge(ui, snapshot, ack)

      {:ok, snapshot} ->
        update(ui, snapshot)

      {:error, snapshot} ->
        update(ui, snapshot)
    end
  end

  def act(ui, _, _), do: ui

  defp update(ui, snapshot),
    do: %{
      ui
      | snapshot: snapshot,
        question: Question.sync(ui.question, snapshot),
        window: if(snapshot.private_cleared, do: HistoryWindow.new(), else: ui.window),
        draft: if(snapshot.private_cleared, do: "", else: ui.draft),
        composer_ack: nil
    }

  defp acknowledge(ui, snapshot, %{accepted_text: text}) do
    next = update(ui, snapshot)
    %{next | draft: if(next.draft == text, do: "", else: next.draft), composer_ack: text}
  end
end
