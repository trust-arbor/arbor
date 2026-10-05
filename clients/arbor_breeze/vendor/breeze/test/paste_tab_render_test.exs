defmodule Breeze.PasteTabRenderTest do
  use ExUnit.Case, async: true

  alias Breeze.Implicit.Textarea

  defmodule View do
    use Breeze.View
    import Breeze.Blocks, only: [textarea: 1]

    def mount(opts, term) do
      {:ok,
       assign(term,
         observer: Keyword.fetch!(opts, :observer),
         draft: "",
         tab_size: Keyword.get(opts, :tab_size, 4)
       )}
    end

    def handle_event("draft", %{value: value}, term) do
      send(term.assigns.observer, {:draft, value})
      {:noreply, assign(term, draft: value)}
    end

    def handle_event("submit", %{value: value}, term) do
      send(term.assigns.observer, {:submitted, value})
      {:noreply, term}
    end

    def render(assigns) do
      ~H"""
      <box class="w-full">
        <.textarea id="draft" class="w-full height-6" default-focus
          textarea-value={@draft} textarea-tab-size={@tab_size}
          br-change="draft" br-submit="submit" />
      </box>
      """
    end
  end

  defp session(opts \\ []) do
    session =
      Breeze.Test.start!(View,
        size: {20, 12},
        theme: Breeze.Theme.builtin(:greenscreen),
        start_opts: [observer: self()] ++ opts
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    Breeze.Test.render_text!(session)
    assert Breeze.Test.focused(session) == "draft"
    session
  end

  defp layout(value, cursor, width, opts \\ []) do
    attrs =
      Map.merge(
        %{:"textarea-value" => value, :"textarea-cursor" => cursor},
        Map.new(opts)
      )

    {:ok, state, _options} = Textarea.init([], attrs, %{})
    box = BackBreeze.Box.new(content: value, style: %{width: width, height: 12})

    {:ok, rendered, overlays: [overlay]} =
      Textarea.animate(:root, box, %{}, state, %{
        layout: %{left: 0, top: 0, viewport_width: width, viewport_height: 12},
        now: 0,
        last_interaction_at: 0,
        theme: Breeze.Theme.builtin(:greenscreen)
      })

    refute rendered.content =~ "\t"
    {rendered.content, {overlay.x, overlay.y}, overlay.char}
  end

  test "native decoded paste, cursor edit, resize and submission preserve the original tabs" do
    session = session()
    Breeze.Test.paste(session, "a\tb\n東京\tc")
    assert_receive {:draft, "a\tb\n東京\tc"}
    rendered = Breeze.Test.render_text!(session)
    assert rendered =~ "a   b"
    assert rendered =~ "東京    c"
    refute rendered =~ "\t"
    refute_receive {:submitted, _}

    Breeze.Test.input(session, "ArrowLeft")
    Breeze.Test.paste(session, "!")
    assert_receive {:draft, "a\tb\n東京\t!c"}
    assert Breeze.Test.render_text!(session) =~ "東京    !c"

    session = Breeze.Test.resize(session, {4, 12})
    refute Breeze.Test.render_text!(session) =~ "\t"
    Breeze.Test.input(session, "Enter")
    assert_receive {:submitted, "a\tb\n東京\t!c"}
  end

  test "public textarea-tab-size controls native rendering without changing submitted text" do
    session = session(tab_size: 8)
    Breeze.Test.paste(session, "a\tb")
    assert_receive {:draft, "a\tb"}
    rendered = Breeze.Test.render_text!(session)
    assert rendered =~ "a       b"
    refute rendered =~ "\t"
    Breeze.Test.input(session, "Enter")
    assert_receive {:submitted, "a\tb"}
  end

  test "cursor positions use tab-stop display columns while raw tabs remain one grapheme" do
    for {cursor, column, char} <- [{0, 0, "a"}, {1, 1, " "}, {2, 4, "b"}, {3, 5, " "}] do
      assert {"a   b", {^column, 0}, ^char} = layout("a\tb", cursor, 20)
    end
  end

  test "wide Unicode and configurable tab stops use the same display widths as the cursor" do
    assert {"東京    c", {4, 0}, " "} = layout("東京\tc", 2, 20)
    assert {"東京    c", {8, 0}, "c"} = layout("東京\tc", 3, 20)

    for tab_size <- [1, 2, 4, 8, 32] do
      expected_column = tab_size * (div(1, tab_size) + 1)
      expected = "a" <> String.duplicate(" ", expected_column - 1) <> "b"

      assert {^expected, {^expected_column, 0}, "b"} =
               layout("a\tb", 2, 40, "textarea-tab-size": tab_size)
    end
  end

  test "tabs clip at viewport edges and restart tab stops after wrapping or explicit newlines" do
    assert {"a   \nb", {0, 1}, "b"} = layout("a\tb", 2, 4)
    assert {"a  \nb", {0, 1}, "b"} = layout("a\tb", 2, 3)
    assert {"a  b", {3, 0}, "b"} = layout("a\tb", 2, 4, "textarea-tab-size": 3)
    assert {" \n", {0, 1}, " "} = layout("\t", 1, 1)
    assert {"a   \nb   \nc", {0, 2}, "c"} = layout("a\tb\tc", 4, 4)
    assert {"a   b\n    c", {4, 1}, "c"} = layout("a\tb\n\tc", 5, 20)
  end

  test "word wrapping relocates the cursor with the carried word after a tab" do
    for {cursor, column} <- [{2, 0}, {3, 1}, {4, 2}, {5, 3}, {6, 4}] do
      assert {"a   \nword", {^column, 1}, _char} = layout("a\tword", cursor, 6)
    end
  end

  test "placeholder tabs render with configured stops without creating a draft" do
    assert {"a       b", {0, 0}, "a"} =
             layout("", 0, 20,
               "textarea-placeholder": "a\tb",
               "textarea-tab-size": 8
             )

    {:ok, state, _options} =
      Textarea.init([], %{:"textarea-placeholder" => "a\tb"}, %{})

    assert state.value == ""
    assert state.cursor == 0
  end

  test "textarea tab size rejects invalid configuration instead of producing unsafe widths" do
    for size <- [0, -1, 33, 1.5, "4", nil] do
      assert_raise ArgumentError, "textarea-tab-size must be an integer between 1 and 32", fn ->
        Textarea.init([], %{:"textarea-tab-size" => size}, %{})
      end
    end
  end
end
