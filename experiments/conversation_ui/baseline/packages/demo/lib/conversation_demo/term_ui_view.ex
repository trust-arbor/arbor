defmodule ConversationDemo.TermUIView do
  @moduledoc "TermUI Elm adapter; pure update returns effect data, handle_info interprets it."
  use TermUI.Elm
  alias ConversationDemo.Interaction
  alias TermUI.Event

  def init(opts) do
    Process.send_after(self(), :dispatch_effects, 20)
    Map.merge(Interaction.new(opts), %{effects: [], scroll: 0})
  end

  def event_to_msg(%Event.Resize{width: width, height: height}, _state),
    do: {:msg, {:resize, width, height}}

  def event_to_msg(%Event.Key{key: :escape}, _state), do: {:msg, :quit}

  def event_to_msg(%Event.Key{key: key}, _state)
      when key in [:enter, :backspace, :page_up, :page_down, :f2, :f3, :f4, :f5, :f6, :f7] do
    translated =
      %{
        enter: "Enter",
        backspace: "Backspace",
        page_up: "PageUp",
        page_down: "PageDown",
        f2: "F2",
        f3: "F3",
        f4: "F4",
        f5: "F5",
        f6: "F6",
        f7: "F7"
      }[key]

    {:msg, {:key, translated}}
  end

  def event_to_msg(%Event.Key{char: char}, _state) when is_binary(char) and char != "",
    do: {:msg, {:key, char}}

  def event_to_msg(_, _), do: :ignore
  def update({:resize, width, height}, state), do: {%{state | width: width, height: height}, []}

  def update({:key, "PageUp"}, state),
    do: {%{state | scroll: state.scroll + max(state.height - 6, 1)}, []}

  def update({:key, "PageDown"}, state),
    do: {%{state | scroll: max(state.scroll - max(state.height - 6, 1), 0)}, []}

  def update({:key, "Enter"}, state),
    do: {%{state | draft: "", effects: state.effects ++ [{:send, state.draft}]}, []}

  def update({:key, key}, state) when key in ["F2", "F3", "F4", "F5", "F6", "F7"],
    do: {%{state | effects: state.effects ++ [{:key, key}]}, []}

  def update({:key, key}, state), do: {Interaction.key(state, key), []}
  def update(:quit, state), do: {state, [TermUI.Command.quit()]}
  def update(_, state), do: {state, []}

  def handle_info(:dispatch_effects, state) do
    Process.send_after(self(), :dispatch_effects, 20)

    next =
      Enum.reduce(state.effects, state, fn
        {:send, text}, ui -> Interaction.act(ui, "send", %{"text" => text})
        {:key, key}, ui -> Interaction.key(ui, key)
      end)

    {%{next | effects: [], draft: state.draft}, []}
  end

  def handle_info(_, state), do: {state, []}

  def view(state) do
    content = rows(state) |> Enum.drop(2) |> Enum.flat_map(&wrap(&1, max(state.width, 1)))
    available = max(state.height - 6, 1)
    start = max(length(content) - available - Map.get(state, :scroll, 0), 0)
    visible = Enum.slice(content, start, available)
    padding = List.duplicate("", max(available - length(visible), 0))

    title =
      if state.width < 35,
        do: "TERMUI / r#{state.snapshot.projection["revision"]}",
        else: hd(rows(state))

    heading = [
      title,
      if(state.connected, do: "Following · PgUp/PgDn", else: "Disconnected · F3 replay")
    ]

    footer = [
      state.error || "",
      "> " <> state.draft,
      "F2 next F3 replay F4 pause",
      "F5 yes F6 no F7 ? Esc exit"
    ]

    stack(:vertical, Enum.map(heading ++ visible ++ padding ++ footer, &text/1))
  end

  def rows(state) do
    projection = state.snapshot.projection

    [
      "CONVERSATION / TERMUI · revision #{projection["revision"]}",
      if(state.connected,
        do: "Following the shared record",
        else: "Disconnected — F3 replays the record"
      )
    ] ++
      Enum.flat_map(projection["blocks"], fn block ->
        ["#{block["role"] || block["type"]} #{block["status"] || ""}", block["text"]]
      end) ++
      Enum.map(state.snapshot.progress, fn {_id, text} -> "… " <> text end) ++
      Enum.map(projection["speech"], &"VOICE [#{&1["type"]}]: #{&1["text"]}")
  end

  def wrap(text, width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn paragraph ->
      {lines, current, _columns} =
        Enum.reduce(String.graphemes(paragraph), {[], "", 0}, fn char,
                                                                 {lines, current, columns} ->
          size = TermUI.Renderer.DisplayWidth.width(char)

          if columns + size > width and current != "",
            do: {lines ++ [current], char, size},
            else: {lines, current <> char, columns + size}
        end)

      lines ++ [current]
    end)
  end

  def run, do: TermUI.Runtime.run(root: __MODULE__)
end
