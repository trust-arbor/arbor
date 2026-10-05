defmodule Breeze.PastePipelineTest do
  use ExUnit.Case, async: true

  defmodule Adapter do
    @behaviour Termite.Terminal.Adapter

    def start(opts) do
      terminal = %{observer: Keyword.fetch!(opts, :observer), reader: make_ref()}
      send(terminal.observer, {:adapter_started, self(), terminal.reader})
      {:ok, terminal}
    end

    def reader(terminal), do: {:ok, terminal.reader}
    def resize(_terminal), do: %{width: 60, height: 12}

    def write(terminal, text) do
      send(terminal.observer, {:terminal_write, text})
      {:ok, terminal}
    end

    def stop(terminal), do: send(terminal.observer, :adapter_stopped) && :ok
  end

  defmodule View do
    use Breeze.View
    import Breeze.Blocks, only: [textarea: 1, scroll: 1]

    def mount(opts, term) do
      observer = Keyword.fetch!(opts, :observer)
      send(observer, {:native_owner, self()})
      send(observer, {:draft, "", []})

      {:ok,
       assign(term,
         observer: observer,
         draft: "",
         submits: [],
         scope: Keyword.get(opts, :owner_revision, 0)
       )}
    end

    def handle_event("draft", %{value: value}, term) do
      send(term.assigns.observer, {:draft, value, term.assigns.submits})
      {:noreply, assign(term, draft: value)}
    end

    def handle_event("submit", %{value: value}, term) do
      submits = term.assigns.submits ++ [value]
      send(term.assigns.observer, {:draft, value, submits})
      {:noreply, assign(term, submits: submits)}
    end

    def handle_event(:input, %{"key" => "Escape"}, term), do: {:stop, term}

    def handle_event(:input, %{"key" => "F2"}, term) do
      send(term.assigns.observer, {:input_blocked, self()})

      receive do
        :release_input -> {:noreply, focus(term, "draft")}
      end
    end

    def handle_event(:input, event, term) do
      send(term.assigns.observer, {:view_key, event})
      {:noreply, term}
    end

    def handle_info({:breeze_paste_rejected, reason}, term) do
      send(term.assigns.observer, {:paste_rejected, reason})
      {:noreply, term}
    end

    def handle_info({:breeze_paste_started, sequence}, term) do
      send(term.assigns.observer, {:paste_started, sequence})
      {:noreply, term}
    end

    def handle_info(:reset_native, term) do
      scope = term.assigns.scope + 1
      send(term.assigns.observer, {:scope_changed, scope})
      {:noreply, term |> reset("draft") |> assign(draft: "", scope: scope)}
    end

    def handle_info(:focus_roundtrip, term) do
      scope = term.assigns.scope + 1
      send(term.assigns.observer, {:scope_changed, scope})
      {:noreply, term |> focus("transcript") |> focus("draft") |> assign(scope: scope)}
    end

    def handle_info(:focus_plain, term) do
      scope = term.assigns.scope + 1
      send(term.assigns.observer, {:scope_changed, scope})
      {:noreply, term |> focus("plain") |> assign(scope: scope), invalidate: false}
    end

    def handle_info(_, term), do: {:noreply, term}

    def render(assigns) do
      ~H"""
      <box class="w-full h-full">
        <box class="height-1">Scope {@scope}</box>
        <box id="plain" class="height-1" focusable>Ordinary view input</box>
        <.scroll id="transcript" class="height-2">Transcript</.scroll>
        <.textarea id="draft" class="w-full height-6 border" default-focus
          textarea-value={@draft} textarea-submit-on-enter={true}
          br-change="draft" br-submit="submit" />
      </box>
      """
    end
  end

  defmodule NestedView do
    use Breeze.View

    def mount(opts, term) do
      observer = Keyword.fetch!(opts, :observer)
      send(observer, {:ancestor_owner, self()})
      {:ok, assign(term, observer: observer, revision: 0)}
    end

    def handle_event(:input, event, term) do
      send(term.assigns.observer, {:parent_key, event})
      {:noreply, term}
    end

    def handle_info({:breeze_paste_started, sequence}, term) do
      send(term.assigns.observer, {:paste_started, sequence})
      {:noreply, term}
    end

    def handle_info(:replace_owner, term) do
      {:noreply, assign(term, revision: term.assigns.revision + 1)}
    end

    def handle_info(:focus_roundtrip, term) do
      send(term.assigns.observer, :ancestor_focus_changed)
      {:noreply, term |> focus(nil) |> focus(term.focused), invalidate: false}
    end

    def handle_info(_, term), do: {:noreply, term}

    def render(assigns) do
      ~H"""
      <box class="w-screen h-screen">
        <live id="child" view={Breeze.PastePipelineTest.View}
          class="w-full h-full"
          start_opts={[observer: @observer, owner_revision: @revision]} />
      </box>
      """
    end
  end

  defmodule MultiLevelView do
    use Breeze.View
    def mount(opts, term), do: {:ok, assign(term, observer: Keyword.fetch!(opts, :observer))}

    def handle_info({:breeze_paste_started, sequence}, term) do
      send(term.assigns.observer, {:paste_started, sequence})
      {:noreply, term}
    end

    def handle_info(_, term), do: {:noreply, term}

    def render(assigns) do
      ~H"""
      <box class="w-screen h-screen">
        <live id="outer" view={Breeze.PastePipelineTest.NestedView}
          class="w-full h-full" start_opts={[observer: @observer]} />
      </box>
      """
    end
  end

  defmodule OriginalImplicit do
    @behaviour Breeze.Implicit
    def init(_, _, last), do: {:ok, Map.put(last, :old_private_marker, true)}
    def handle_modifiers(_, _, _), do: []
  end

  defmodule ReplacementImplicit do
    @behaviour Breeze.Implicit
    def init(_, _, last),
      do: {:ok, Map.put(last, :inherited_old_state, Map.has_key?(last, :old_private_marker))}

    def handle_modifiers(_, _, _), do: []
  end

  defmodule ReplacementView do
    use Breeze.View
    def mount(_, term), do: {:ok, assign(term, switched: false)}
    def handle_info(:replace, term), do: {:noreply, assign(term, switched: true)}

    def render(assigns) do
      ~H"""
      <box>
        <box :if={!@switched} id="editor" implicit={Breeze.PastePipelineTest.OriginalImplicit}>Original</box>
        <box :if={@switched} id="editor" implicit={Breeze.PastePipelineTest.ReplacementImplicit}>Replacement</box>
      </box>
      """
    end
  end

  defmodule HiddenView do
    use Breeze.View
    import Breeze.Blocks, only: [textarea: 1]
    def mount(_, term), do: {:ok, assign(term, visible: true)}
    def handle_info(:hide, term), do: {:noreply, assign(term, visible: false)}
    def handle_info(:show, term), do: {:noreply, assign(term, visible: true)}
    def handle_info(:reset_editor, term), do: {:noreply, reset(term, "editor")}

    def render(assigns) do
      ~H"""
      <box class="w-screen h-screen">
        <.textarea :if={@visible} id="editor" class="w-full height-3" textarea-value="private" default-focus />
      </box>
      """
    end
  end

  defp start(opts \\ []) do
    {check_bracketed_mode?, opts} = Keyword.pop(opts, :check_bracketed_mode, true)

    {:ok, session} =
      Breeze.Server.start_link(
        Keyword.merge(
          [
            view: View,
            start_opts: [observer: self()],
            terminal_opts: [adapter: Adapter, observer: self()],
            theme: Breeze.Theme.builtin(:greenscreen),
            logger: false,
            reload: false,
            inspector: false
          ],
          opts
        )
      )

    assert_receive {:adapter_started, ^session, reader}
    assert_receive {:draft, "", []}
    if check_bracketed_mode?, do: assert_receive({:terminal_write, "\e[?2004h"})
    on_exit(fn -> Breeze.Server.stop(session) end)
    {session, reader}
  end

  defp raw(session, reader, chunks),
    do: Enum.each(chunks, &send(session, {reader, {:data, &1}}))

  defp bytes(text), do: for(<<byte <- text>>, do: <<byte>>)

  defp wait_frame(fragment, timeout \\ 1_000) do
    wait_frame_until(fragment, System.monotonic_time(:millisecond) + timeout, [])
  end

  defp wait_full_frame(session, reader, fragment) do
    # The public resize notification requests a complete frame. Incremental
    # terminal writes may contain only the changed digit, not the full label.
    send(session, {reader, {:signal, :winch}})
    wait_frame(fragment)
  end

  defp wait_frame_until(fragment, deadline, frames) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:terminal_write, text} ->
        frame = BackBreeze.Utils.strip_escape_chars(text)

        if String.contains?(frame, fragment),
          do: :ok,
          else: wait_frame_until(fragment, deadline, Enum.take([frame | frames], 3))
    after
      remaining ->
        flunk("Native frame never contained #{inspect(fragment)}; observed #{inspect(frames)}")
    end
  end

  test "raw paste reset security regression discards late closure and allows a fresh turn" do
    {session, reader} = start()
    raw(session, reader, ["\e[200~private\n"])
    assert_receive {:paste_started, _}, 1_000
    send(session, {reader, {:event, :reset_native}})
    assert_receive {:scope_changed, 1}
    wait_full_frame(session, reader, "Scope 1")
    raw(session, reader, ["late\n\e[201~", "x", "\r"])
    assert_receive {:draft, "x", ["x"]}, 1_000
    refute_receive {:draft, "private\nlate\n", _}
    raw(session, reader, ["\e[200~fresh\n日本語\e[201~"])
    assert_receive {:draft, "xfresh\n日本語", ["x"]}, 1_000
    raw(session, reader, ["\r"])
    assert_receive {:draft, "xfresh\n日本語", ["x", "xfresh\n日本語"]}, 1_000
  end

  test "raw paste focus-away-and-back security regression rejects the original generation" do
    {session, reader} = start()
    raw(session, reader, ["\e[200~stale\n"])
    assert_receive {:paste_started, _}, 1_000
    send(session, {reader, {:event, :focus_roundtrip}})
    assert_receive {:scope_changed, 1}
    wait_full_frame(session, reader, "Scope 1")
    raw(session, reader, ["body\e[201~", "x", "\r"])
    assert_receive {:draft, "x", ["x"]}, 1_000
    refute_receive {:draft, "stale\nbody", _}
  end

  test "completed raw paste queued behind input cannot rebind after an owner reset" do
    {session, reader} = start()
    send(session, {reader, {:event, :focus_plain}})
    assert_receive {:scope_changed, 1}
    wait_full_frame(session, reader, "Scope 1")
    raw(session, reader, ["\eOQ"])
    assert_receive {:input_blocked, native_owner}, 1_000
    raw(session, reader, ["\e[200~private\nbody\e[201~"])
    # Public runtime API calls provide a mailbox barrier without inspecting
    # private queue state: the reader forwarded both events and the server
    # admitted them while the earlier ordinary key is still pending.
    runtime = Breeze.Server.runtime_pid(session)
    assert is_map(Breeze.Server.Diagnostics.stats(runtime))
    # This ordinary public view-info callback is queued behind the blocked
    # key. The paste was already received, but its ordered start is pending.
    send(native_owner, :reset_native)
    send(native_owner, :release_input)
    assert_receive {:scope_changed, 2}, 1_000
    assert_receive {:paste_started, _}, 1_000
    wait_full_frame(session, reader, "Scope 2")
    raw(session, reader, ["x", "\r"])
    assert_receive {:draft, "x", ["x"]}, 1_000
    refute_receive {:draft, "private\nbody", _}
  end

  test "a queued ordinary Tab determines the paste target without invoking paste keybindings" do
    {session, reader} = start()
    raw(session, reader, ["\e[Z\e[200~private\nbody\e[201~"])
    assert_receive {:paste_started, _}, 1_000
    refute_receive {:draft, "private\nbody", _}
    refute_receive {:view_key, _}
    raw(session, reader, ["\t", "x", "\r"])
    assert_receive {:draft, "x", ["x"]}, 1_000
  end

  test "raw paste completion cannot cross a replaced live-child owner" do
    {session, reader} = start(view: NestedView)
    wait_frame("Scope 0")
    raw(session, reader, ["\e[200~private\n"])
    assert_receive {:paste_started, _}, 1_000
    send(session, {reader, {:event, :replace_owner}})
    assert_receive {:draft, "", []}, 1_000
    wait_full_frame(session, reader, "Scope 1")
    raw(session, reader, ["body\e[201~", "x", "\r"])
    assert_receive {:draft, "x", ["x"]}, 1_000
    refute_receive {:draft, "private\nbody", _}
  end

  test "fresh raw Unicode multiline paste reaches the focused interactive live child" do
    {session, reader} = start(view: NestedView)
    wait_frame("Scope 0")
    raw(session, reader, ["\e[200~日本語\r\nchild\e[201~"])
    assert_receive {:draft, "日本語\nchild", []}, 1_000
    raw(session, reader, ["\r"])
    assert_receive {:draft, "日本語\nchild", ["日本語\nchild"]}, 1_000
    refute_receive {:parent_key, _}
    refute_receive {:view_key, _}
  end

  test "raw paste traverses multiple live owners and rejects an intermediate focus generation change" do
    {session, reader} = start(view: MultiLevelView)
    assert_receive {:ancestor_owner, ancestor}
    wait_frame("Scope 0")
    raw(session, reader, ["\e[200~日本語\nleaf\e[201~"])
    assert_receive {:draft, "日本語\nleaf", []}, 1_000
    assert_receive {:paste_started, _}, 1_000
    raw(session, reader, ["\e[200~stale\n"])
    assert_receive {:paste_started, _}, 1_000
    send(ancestor, :focus_roundtrip)
    assert_receive :ancestor_focus_changed
    raw(session, reader, ["body\e[201~", "x", "\r"])
    assert_receive {:draft, "日本語\nleafx", ["日本語\nleafx"]}, 1_000
    refute_receive {:draft, "日本語\nleafstale\nbody", _}
  end

  test "completed raw paste queued behind nested input cannot rebind after the child resets" do
    {session, reader} = start(view: NestedView)
    assert_receive {:native_owner, native_owner}
    wait_frame("Scope 0")
    # A public child info callback selects non-implicit input without changing
    # the root's namespace string. It defers repaint deliberately so an owner
    # reset below cannot be mistaken for a root-only scope transition.
    send(native_owner, :focus_plain)
    assert_receive {:scope_changed, 1}
    raw(session, reader, ["\eOQ"])
    assert_receive {:input_blocked, ^native_owner}, 1_000
    raw(session, reader, ["\e[200~private\nbody\e[201~"])
    runtime = Breeze.Server.runtime_pid(session)
    assert is_map(Breeze.Server.Diagnostics.stats(runtime))
    send(native_owner, :reset_native)
    send(native_owner, :release_input)
    assert_receive {:scope_changed, 2}, 1_000
    assert_receive {:paste_started, _}, 1_000
    wait_full_frame(session, reader, "Scope 2")
    raw(session, reader, ["x", "\r"])
    assert_receive {:draft, "x", ["x"]}, 1_000
    refute_receive {:draft, "private\nbody", _}
  end

  test "raw paste rejects a nested native owner's focus roundtrip while root focus is unchanged" do
    {session, reader} = start(view: NestedView)
    assert_receive {:native_owner, native_owner}
    wait_frame("Scope 0")
    raw(session, reader, ["\e[200~private\n"])
    assert_receive {:paste_started, _}, 1_000
    send(native_owner, :focus_roundtrip)
    assert_receive {:scope_changed, 1}
    wait_full_frame(session, reader, "Scope 1")
    raw(session, reader, ["body\e[201~", "x", "\r"])
    assert_receive {:draft, "x", ["x"]}, 1_000
    refute_receive {:draft, "private\nbody", _}
  end

  test "raw split Unicode multiline paste inserts at the native cursor without submission" do
    {session, reader} = start()
    raw(session, reader, ["a", "b"])
    assert_receive {:draft, "ab", []}
    raw(session, reader, ["\e[D"])
    raw(session, reader, bytes("\e[200~日本語\r\nsecond\tline\e[201~"))
    assert_receive {:draft, "a日本語\nsecond\tlineb", []}, 1_000
    refute_receive {:view_key, _}
    # Unsupported controls are rejected as one body, never interpreted as
    # Ctrl+C/Enter or partially inserted before a following ordinary Enter.
    raw(session, reader, ["\e[200~\x03\r\n\e[201~"])
    raw(session, reader, ["\r"])
    assert_receive {:draft, "a日本語\nsecond\tlineb", ["a日本語\nsecond\tlineb"]}, 1_000
  end

  test "raw multiline-paste security regression uses released shell-shaped reader frames" do
    {session, reader} = start(check_bracketed_mode: false)
    # Termite's OTP28 shell reader emits completed CSI markers and individual
    # Unicode codepoints. This witness matches that actual reader contract.
    raw(session, reader, ["\e[200~"] ++ String.codepoints("日本語\r\nsecond") ++ ["\e[201~"])
    assert_receive {:draft, "日本語\nsecond", []}, 1_000
    raw(session, reader, ["\r"])
    assert_receive {:draft, "日本語\nsecond", ["日本語\nsecond"]}, 1_000
  end

  test "paste bodies bypass transcript keybindings and only ordinary Escape exits" do
    {session, reader} = start()
    monitor = Process.monitor(session)
    raw(session, reader, ["\e[Z"])
    raw(session, reader, ["\e[200~q\e[201~", "\e[200~F9\e[201~", "\e[200~\r\n\e[201~"])
    refute_receive {:view_key, _}
    refute_receive {:DOWN, ^monitor, _, _, _}
    raw(session, reader, ["\e"])
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
    assert_receive {:terminal_write, "\e[?2004l"}
  end

  test "oversize and incomplete paste never replay newlines; closing marker restores input" do
    {session, reader} = start(paste_max_bytes: 3, paste_timeout_ms: 20)
    raw(session, reader, ["\e[200~toolarge\r\n\e[201~"])
    assert_receive {:paste_rejected, :too_large}, 1_000
    refute_receive {:draft, _, [_ | _]}
    raw(session, reader, ["\e[200~a\r"])
    assert_receive {:paste_rejected, :incomplete}, 1_000
    raw(session, reader, ["late\r\n\e[201~", "x"])
    assert_receive {:draft, "x", []}, 1_000
    refute_receive {:draft, _, [_ | _]}
    raw(session, reader, ["\r"])
    assert_receive {:draft, "x", ["x"]}, 1_000
  end

  test "explicit stop restores bracketed mode through the normal terminal cleanup path" do
    {session, _reader} = start()
    :ok = Breeze.Server.stop(session)
    assert_receive {:terminal_write, "\e[?2004l"}
    refute_receive {:terminal_write, "\e[?2004l"}
  end

  test "decoded paste reaches an opt-in native textarea inside a live child" do
    session = Breeze.Test.start!(NestedView, start_opts: [observer: self()])
    on_exit(fn -> Breeze.Test.stop(session) end)
    assert Breeze.Test.render_text!(session) =~ "Transcript"
    assert_receive {:draft, "", []}
    Breeze.Test.focus(session, "child::draft")
    Breeze.Test.paste(session, "nested\n日本語")
    assert_receive {:draft, "nested\n日本語", []}
    refute_receive {:parent_key, _}
    refute_receive {:view_key, _}
    assert Breeze.Test.render_text!(session) =~ "日本語"
  end

  test "security regression a replacement implicit at the same ID never inherits the former module state" do
    session = Breeze.Test.start!(ReplacementView)
    on_exit(fn -> Breeze.Test.stop(session) end)
    assert Breeze.Test.render_text!(session) =~ "Original"
    {OriginalImplicit, original} = Breeze.Test.metadata(session).implicit_state["editor"]
    Breeze.Test.info(session, :replace)
    assert Breeze.Test.render_text!(session) =~ "Replacement"
    {ReplacementImplicit, replacement} = Breeze.Test.metadata(session).implicit_state["editor"]
    refute replacement.inherited_old_state
    refute replacement.__breeze_instance_ref__ == original.__breeze_instance_ref__
  end

  test "security regression reset also retires a hidden retained native instance" do
    session = Breeze.Test.start!(HiddenView)
    on_exit(fn -> Breeze.Test.stop(session) end)
    Breeze.Test.render_text!(session)
    {_, original} = Breeze.Test.metadata(session).implicit_state["editor"]
    Breeze.Test.info(session, :hide)
    Breeze.Test.render_text!(session)
    refute Map.has_key?(Breeze.Test.metadata(session).implicit_state, "editor")
    Breeze.Test.info(session, :reset_editor)
    Breeze.Test.info(session, :show)
    assert Breeze.Test.render_text!(session) =~ "private"
    {_, replacement} = Breeze.Test.metadata(session).implicit_state["editor"]
    refute replacement.__breeze_instance_ref__ == original.__breeze_instance_ref__
  end
end
