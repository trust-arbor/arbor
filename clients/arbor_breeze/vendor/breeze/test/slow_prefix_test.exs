defmodule Breeze.SlowPrefixTest do
  use ExUnit.Case, async: false

  defmodule Adapter do
    @behaviour Termite.Terminal.Adapter
    def start(opts) do
      terminal = %{observer: Keyword.fetch!(opts, :observer), reader: make_ref()}
      send(terminal.observer, {:reader, terminal.reader})
      {:ok, terminal}
    end

    def reader(term), do: {:ok, term.reader}
    def resize(_), do: %{width: 60, height: 12}
    def write(term, _), do: {:ok, term}
    def stop(_), do: :ok
  end

  defmodule View do
    use Breeze.View
    import Breeze.Blocks, only: [textarea: 1]

    def mount(opts, term),
      do: {:ok, assign(term, observer: Keyword.fetch!(opts, :observer), draft: "", submits: [])}

    def handle_event("draft", %{value: text}, term) do
      send(term.assigns.observer, {:draft, text, term.assigns.submits})
      {:noreply, assign(term, draft: text)}
    end

    def handle_event("submit", %{value: text}, term) do
      submissions = term.assigns.submits ++ [text]
      send(term.assigns.observer, {:draft, text, submissions})
      {:noreply, assign(term, submits: submissions)}
    end

    def handle_event(:input, event, term) do
      send(term.assigns.observer, {:key, event["key"], System.monotonic_time(:millisecond)})
      {:noreply, term}
    end

    def handle_info({:breeze_paste_rejected, reason}, term) do
      send(term.assigns.observer, {:rejected, reason})
      {:noreply, term}
    end

    def handle_info(_, term), do: {:noreply, term}

    def render(assigns) do
      ~H"""
      <box class="w-full h-full">
        <.textarea
          id="draft"
          class="w-full height-5"
          default-focus
          textarea-value={@draft}
          textarea-submit-on-enter={true}
          br-change="draft"
          br-submit="submit"
        />
      </box>
      """
    end
  end

  defp start(opts \\ []) do
    {:ok, pid} =
      Breeze.Server.start_link(
        Keyword.merge(
          [
            view: View,
            start_opts: [observer: self()],
            theme: Breeze.Theme.builtin(:greenscreen),
            terminal_opts: [adapter: Adapter, observer: self()],
            inspector: false,
            logger: false,
            reload: false
          ],
          opts
        )
      )

    assert_receive {:reader, reader}
    runtime = Breeze.Server.runtime_pid(pid)
    assert %{accepts_paste: true} = Breeze.Server.focused_implicit_metadata(runtime)
    on_exit(fn -> if Process.alive?(pid), do: Breeze.Server.stop(pid) end)
    {pid, reader}
  end

  defp raw(pid, reader, data), do: send(pid, {reader, {:data, data}})

  for {label, newline} <- [{"CRLF", "\r\n"}, {"LF", "\n"}] do
    test "security regression slow native #{label} framing never submits before explicit Enter" do
      {pid, reader} = start()
      source = "\e[200~slow" <> unquote(newline) <> "body\e[201~"
      chunks = for <<chunk::binary-size(3) <- source>>, do: chunk
      wire = IO.iodata_to_binary(chunks)

      for chunk <- chunks do
        raw(pid, reader, chunk)
        Process.sleep(250)
      end

      tail = binary_part(source, byte_size(wire), byte_size(source) - byte_size(wire))
      raw(pid, reader, tail)
      assert_receive {:draft, "slow\nbody", []}, 1_000
      refute_receive {:draft, _, [_ | _]}
      raw(pid, reader, "\r")
      assert_receive {:draft, "slow\nbody", ["slow\nbody"]}, 1_000
    end
  end

  test "security regression delayed framing cannot reinterpret a bare body CR as Enter" do
    {pid, reader} = start()
    raw(pid, reader, "\e[2")
    Process.sleep(250)
    raw(pid, reader, "00~")
    raw(pid, reader, "slow")
    raw(pid, reader, "\r")
    raw(pid, reader, "\n")
    raw(pid, reader, "body")
    raw(pid, reader, "\e[201~")
    refute_receive {:draft, _, [_ | _]}, 300
    assert_receive {:draft, "slow\nbody", []}, 1_000
    raw(pid, reader, "\r")
    assert_receive {:draft, "slow\nbody", ["slow\nbody"]}, 1_000
  end

  test "expired deeper framing discards late CRLF until closure then fresh explicit input works" do
    {pid, reader} = start(paste_prefix_timeout_ms: 20)
    raw(pid, reader, "\e[2")
    assert_receive {:rejected, :incomplete}, 1_000
    raw(pid, reader, "00~late\r\nbody\e[201~fresh")
    assert_receive {:draft, "fresh", []}, 1_000
    refute_receive {:draft, _, [_ | _]}
    raw(pid, reader, "\r")
    assert_receive {:draft, "fresh", ["fresh"]}, 1_000
  end

  test "expired standalone Escape cannot replay its delayed paste continuation" do
    {pid, reader} = start(paste_prefix_timeout_ms: 20)
    raw(pid, reader, "\e")
    assert_receive {:key, "Escape", _}, 1_000
    raw(pid, reader, "[2")
    raw(pid, reader, "00~late\r\nbody\e[201~fresh")
    assert_receive {:rejected, :incomplete}, 1_000
    assert_receive {:draft, "fresh", []}, 1_000
    refute_receive {:draft, _, [_ | _]}
    raw(pid, reader, "\r")
    assert_receive {:draft, "fresh", ["fresh"]}, 1_000
  end

  test "ordinary F9 CSI20 and bounded standalone Escape remain normal input" do
    {pid, reader} = start(paste_prefix_timeout_ms: 30)
    raw(pid, reader, "\e[20~")
    assert_receive {:key, "F9", _}, 1_000
    raw(pid, reader, "\e")
    assert_receive {:key, "Escape", _}, 1_000
    raw(pid, reader, "x")
    assert_receive {:draft, "x", []}, 1_000
    raw(pid, reader, "\r")
    assert_receive {:draft, "x", ["x"]}, 1_000
    refute_receive {:rejected, _}
  end

  test "empty fragments do not renew bounded prefix ambiguity" do
    {pid, reader} = start(paste_prefix_timeout_ms: 80)
    raw(pid, reader, "\e")
    scheduled = :sys.get_state(pid).paste_timeout_ref
    assert is_reference(scheduled)

    for _ <- 1..20 do
      raw(pid, reader, "")
      Process.sleep(25)
    end

    ended = System.monotonic_time(:millisecond)
    assert_receive {:key, "Escape", delivered}, 1_000
    assert delivered < ended
  end

  test "stale prefix timeout cannot abort a newer full paste" do
    {pid, reader} = start()
    raw(pid, reader, "\e[2")
    old = :sys.get_state(pid).paste_timeout_ref
    raw(pid, reader, "00~fresh\r\n")
    :sys.get_state(pid)
    send(pid, {:paste_timeout, old})
    raw(pid, reader, "body\e[201~")
    assert_receive {:draft, "fresh\nbody", []}, 1_000
    refute_receive {:rejected, _}
  end
end
