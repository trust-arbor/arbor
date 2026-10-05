defmodule Breeze.InputRouter do
  @moduledoc false

  use GenServer

  alias Breeze.InputRouter.{IExShellProxy, SilentGroupLeader, TerminalCleanup, TerminalStart}

  alias Termite.Terminal.IODevice
  alias Breeze.InputCapture
  alias Breeze.Theme.Probe, as: ThemeProbe
  alias Breeze.Clipboard.Probe, as: ClipboardProbe

  defstruct [
    :terminal,
    :reader,
    :server_pid,
    :child_view_supervisor,
    :remote_inspector_supervisor,
    :theme_probe,
    :clipboard_probe,
    :clipboard_buffer_ref,
    :iex_shell_proxy,
    :silent_group_leader,
    :terminal_cleanup,
    :paste_decoder,
    :paste_timeout_ref,
    :paste_timeout_timer,
    :paste_timeout_mode,
    paste_timeout_ms: 30_000,
    paste_prefix_timeout_ms: 500,
    alt_screen?: true,
    enhanced_keyboard?: true,
    terminal_restored?: false,
    global_keybindings: []
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    opts = maybe_put_iex_terminal_size_override(opts)
    alt_screen? = Keyword.get(opts, :alt_screen, true)
    hide_cursor? = Keyword.get(opts, :hide_cursor, true)
    enhanced_keyboard? = Keyword.get(opts, :enhanced_keyboard, true)
    bracketed_paste? = Keyword.get(opts, :bracketed_paste, true)

    paste_decoder =
      Breeze.BracketedPaste.new(max_bytes: Keyword.get(opts, :paste_max_bytes, 1_048_576))

    paste_timeout_ms = Keyword.get(opts, :paste_timeout_ms, 30_000)
    paste_prefix_timeout_ms = Keyword.get(opts, :paste_prefix_timeout_ms, 500)

    unless is_integer(paste_timeout_ms) and paste_timeout_ms > 0,
      do: raise(ArgumentError, ":paste_timeout_ms must be a positive integer")

    unless is_integer(paste_prefix_timeout_ms) and paste_prefix_timeout_ms > 0,
      do: raise(ArgumentError, ":paste_prefix_timeout_ms must be a positive integer")

    mouse = Keyword.get(opts, :mouse, false)

    %TerminalStart{
      terminal: terminal,
      iex_shell_proxy: iex_shell_proxy,
      silent_group_leader: silent_group_leader,
      owned?: terminal_owned?
    } = terminal_start = build_terminal(opts)

    terminal_cleanup =
      register_terminal_cleanup(terminal_start,
        owned?: terminal_owned?,
        alt_screen?: alt_screen?,
        enhanced_keyboard?: enhanced_keyboard?,
        bracketed_paste?: bracketed_paste?,
        register: internal_get(opts, :at_exit_register, &System.at_exit/1)
      )

    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      reader = terminal.reader
      terminal = if alt_screen?, do: Termite.Screen.alt_screen(terminal), else: terminal
      terminal = if enhanced_keyboard?, do: enable_enhanced_keyboard(terminal), else: terminal

      terminal =
        if bracketed_paste?, do: Termite.Terminal.write(terminal, "\e[?2004h"), else: terminal

      terminal = if hide_cursor?, do: Termite.Screen.hide_cursor(terminal), else: terminal
      terminal = enable_mouse(terminal, mouse)
      terminal = Termite.Screen.clear_screen(terminal)

      {terminal, deferred_messages} =
        maybe_complete_initial_theme_probe(terminal, Keyword.get(opts, :theme))

      {:ok, child_view_supervisor} = Breeze.ChildViewSupervisor.start_link()
      remote_inspector_supervisor = maybe_start_remote_inspector_supervisor(opts)

      server_opts =
        opts
        |> Keyword.put(:terminal, terminal)
        |> Keyword.put(:input_router, self())
        |> put_internal(:child_view_supervisor, child_view_supervisor)
        |> put_internal(:terminal_cleanup, terminal_cleanup)
        |> put_internal(:remote_inspector_supervisor, remote_inspector_supervisor)

      server_pid =
        case Breeze.Server.start_app_link(server_opts) do
          {:ok, server_pid} ->
            server_pid

          {:error, reason} ->
            Breeze.RemoteInspector.Supervisor.stop(remote_inspector_supervisor)
            Breeze.ChildViewSupervisor.stop(child_view_supervisor)
            exit(reason)
        end

      Process.unlink(server_pid)
      Process.monitor(server_pid)

      state = %__MODULE__{
        terminal: terminal,
        reader: reader,
        server_pid: server_pid,
        child_view_supervisor: child_view_supervisor,
        remote_inspector_supervisor: remote_inspector_supervisor,
        alt_screen?: alt_screen?,
        enhanced_keyboard?: enhanced_keyboard?,
        iex_shell_proxy: iex_shell_proxy,
        silent_group_leader: silent_group_leader,
        terminal_cleanup: terminal_cleanup,
        paste_decoder: paste_decoder,
        paste_timeout_ms: paste_timeout_ms,
        paste_prefix_timeout_ms: paste_prefix_timeout_ms,
        global_keybindings: Keyword.get(opts, :global_keybindings, [])
      }

      Enum.each(Enum.reverse(deferred_messages), &send(self(), &1))

      {:ok, state, {:continue, {:maybe_start_theme_probe, Keyword.get(opts, :theme)}}}
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__

        cleanup_failed_start(
          terminal,
          terminal_cleanup,
          nil,
          nil,
          iex_shell_proxy,
          silent_group_leader
        )

        :erlang.raise(kind, reason, stacktrace)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  @impl true
  def handle_continue({:maybe_start_theme_probe, theme}, state) do
    state = maybe_start_theme_probe(state, theme)
    Process.send_after(self(), :clipboard_probe_timeout, ClipboardProbe.timeout_ms())
    terminal = Termite.Terminal.write(state.terminal, ClipboardProbe.query())
    {:noreply, %{state | terminal: terminal, clipboard_probe: ClipboardProbe.new()}}
  end

  @impl true
  def handle_info({reader, {:data, data}}, %{reader: reader} = state) do
    previous_decoder = state.paste_decoder
    {events, decoder} = Breeze.BracketedPaste.feed_framed(previous_decoder, data)
    state = %{state | paste_decoder: decoder}

    state =
      if Enum.any?(events, fn event -> elem(event, 0) in [:paste_start, :paste, :paste_error] end),
         do: %{state | paste_timeout_mode: nil},
         else: state

    # Empty or repeated prefix input cannot extend ambiguity. A start marker
    # has at most five pending bytes; only real progress refreshes its deadline.
    state =
      if decoder == previous_decoder and events == [],
        do: state,
        else: schedule_paste_timeout(state)

    route_paste_events(events, reader, state)
  end

  def handle_info({:paste_timeout, ref}, %{paste_timeout_ref: ref} = state) do
    {events, decoder} = Breeze.BracketedPaste.flush(state.paste_decoder)

    events =
      Enum.map(events, fn
        {:paste_error, reason} -> {:paste_error, decoder.sequence, reason}
        event -> event
      end)

    route_paste_events(events, state.reader, %{
      state
      | paste_decoder: decoder,
        paste_timeout_ref: nil,
        paste_timeout_timer: nil,
        paste_timeout_mode: nil
    })
  end

  def handle_info({:paste_timeout, _ref}, state), do: {:noreply, state}

  def handle_info(:clipboard_probe_timeout, %{clipboard_probe: probe} = state)
      when is_map(probe) do
    {:noreply, %{state | clipboard_probe: ClipboardProbe.expire(probe)}}
  end

  def handle_info({:clipboard_buffer_timeout, ref}, %{clipboard_buffer_ref: ref} = state) do
    {probe, data} = ClipboardProbe.flush(state.clipboard_probe)

    route_terminal_data(state.reader, data, %{
      state
      | clipboard_probe: probe,
        clipboard_buffer_ref: nil
    })
  end

  def handle_info({:clipboard_buffer_timeout, _ref}, state), do: {:noreply, state}

  def handle_info({reader, {:signal, :winch}} = message, %{reader: reader} = state) do
    send(state.server_pid, message)
    {:noreply, state}
  end

  def handle_info({reader, {:event, _event}} = message, %{reader: reader} = state) do
    send(state.server_pid, message)
    {:noreply, state}
  end

  def handle_info({reader, {:signal, :hup}}, %{reader: reader} = state) do
    stop(state)
  end

  def handle_info({:ensure_runtime_palette, :system}, state) do
    {:noreply, maybe_start_theme_probe(state, :system)}
  end

  def handle_info(
        {:theme_probe_timeout, key, ref},
        %{theme_probe: %{key: key, ref: ref, status: :active} = probe} = state
      ) do
    {:noreply, start_theme_probe_drain(state, probe)}
  end

  def handle_info({:theme_probe_timeout, _key, _ref}, state), do: {:noreply, state}

  def handle_info(
        {:theme_probe_drain_timeout, key, ref},
        %{theme_probe: %{key: key, ref: ref, status: :draining} = probe} = state
      ) do
    unless Map.get(probe, :finished?, false) do
      ThemeProbe.finish_runtime_palette_probe(state.terminal, probe.palette)
    end

    {:noreply, %{state | theme_probe: nil}}
  end

  def handle_info({:theme_probe_drain_timeout, _key, _ref}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{server_pid: pid} = state) do
    {:stop, session_exit_reason(reason), state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:runtime_pid, _from, state) do
    {:reply, state.server_pid, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_server(state.server_pid)

    try do
      restore_terminal(state)
    after
      Breeze.RemoteInspector.Supervisor.stop(state.remote_inspector_supervisor)
      Breeze.ChildViewSupervisor.stop(state.child_view_supervisor)
      IExShellProxy.stop(state.iex_shell_proxy)
      SilentGroupLeader.stop(state.silent_group_leader)
    end

    :ok
  end

  defp maybe_start_remote_inspector_supervisor(opts) do
    inspector = %{inspector: Keyword.get(opts, :inspector, false)}

    if Breeze.Inspector.enabled?(inspector) and Breeze.Inspector.remote?(inspector) do
      {:ok, supervisor} = Breeze.RemoteInspector.Supervisor.start_link()
      supervisor
    end
  end

  defp stop_global_key?(key, state),
    do:
      Breeze.GlobalKeybindings.stop_action?(normalize_key_event(key), state) and
        not focused_implicit_captures_key?(key, state)

  defp route_reader_data(reader, data, state) do
    decoded = decode_input(data)

    cond do
      forced_stop_input?(data, decoded) and
          not focused_implicit_captures_decoded_input?(decoded, state) ->
        stop(state)

      stop_decoded_input?(decoded, state) ->
        stop(state)

      true ->
        forward_reader_data(reader, data, state)
    end
  end

  defp schedule_paste_timeout(state) do
    if state.paste_decoder.mode == :paste and state.paste_timeout_mode == :paste do
      state
    else
      schedule_new_paste_timeout(state)
    end
  end

  defp schedule_new_paste_timeout(state) do
    if state.paste_timeout_timer, do: Process.cancel_timer(state.paste_timeout_timer)

    if Breeze.BracketedPaste.pending?(state.paste_decoder) and
         state.paste_decoder.mode != :discard do
      ref = make_ref()
      # A bounded prefix interval permits slow native framing. Prefix expiry
      # keeps late continuations guarded; active paste expiry discards its body.
      timeout =
        if state.paste_decoder.mode in [:idle, :retired_prefix],
          do: state.paste_prefix_timeout_ms,
          else: state.paste_timeout_ms

      timer = Process.send_after(self(), {:paste_timeout, ref}, timeout)

      %{
        state
        | paste_timeout_ref: ref,
          paste_timeout_timer: timer,
          paste_timeout_mode: state.paste_decoder.mode
      }
    else
      %{state | paste_timeout_ref: nil, paste_timeout_timer: nil, paste_timeout_mode: nil}
    end
  end

  defp route_paste_events([], _reader, state), do: {:noreply, state}

  defp route_paste_events([{:data, data} | rest], reader, state) do
    {state, data} = consume_clipboard_reply(state, data)

    case route_terminal_data(reader, data, state) do
      {:noreply, state} -> route_paste_events(rest, reader, state)
      reply -> reply
    end
  end

  defp route_paste_events([{:paste_start, sequence} | rest], reader, state) do
    send(state.server_pid, {reader, {:paste_start, sequence}})
    route_paste_events(rest, reader, state)
  end

  defp route_paste_events([{:paste, sequence, text} | rest], reader, state) do
    send(state.server_pid, {reader, {:paste, sequence, text}})
    route_paste_events(rest, reader, state)
  end

  defp route_paste_events([{:paste_error, sequence, reason} | rest], reader, state) do
    send(state.server_pid, {reader, {:paste_cancel, sequence}})
    send(state.server_pid, {reader, {:event, {:breeze_paste_rejected, reason}}})
    route_paste_events(rest, reader, state)
  end

  defp forward_reader_data(reader, data, state) do
    send(state.server_pid, {reader, {:data, data}})
    {:noreply, state}
  end

  defp theme_probe_reply?(state, data) do
    is_map(state.theme_probe) and
      theme_probe_data?(state.theme_probe.buffer, data)
  end

  defp route_terminal_data(_reader, "", state), do: {:noreply, state}

  defp route_terminal_data(reader, data, state) do
    if theme_probe_reply?(state, data) do
      {:noreply, consume_theme_probe_reply(state, data)}
    else
      route_reader_data(reader, data, state)
    end
  end

  defp consume_clipboard_reply(%{clipboard_probe: nil} = state, data), do: {state, data}

  defp consume_clipboard_reply(state, data) when is_binary(data) do
    {probe, input, queries} = ClipboardProbe.feed(state.clipboard_probe, data)
    terminal = Enum.reduce(queries, state.terminal, &Termite.Terminal.write(&2, &1))

    if probe.clipboard != state.clipboard_probe.clipboard do
      send(state.server_pid, {:breeze_clipboard, state.reader, probe.clipboard})
    end

    ref = if probe.buffer != "", do: make_ref()
    if ref, do: Process.send_after(self(), {:clipboard_buffer_timeout, ref}, 50)
    {%{state | terminal: terminal, clipboard_probe: probe, clipboard_buffer_ref: ref}, input}
  end

  defp consume_clipboard_reply(state, data), do: {state, data}

  defp theme_probe_data?(buffer, data) when is_binary(data) do
    String.starts_with?(data, "\e]") or incomplete_theme_probe_reply?(buffer)
  end

  defp theme_probe_data?(_buffer, _data), do: false

  defp incomplete_theme_probe_reply?(buffer) when is_binary(buffer) do
    :binary.match(buffer, "\e]") != :nomatch
  end

  defp incomplete_theme_probe_reply?(_buffer), do: false

  defp stop_decoded_input?({:key, key}, state), do: stop_global_key?(key, state)
  defp stop_decoded_input?(_decoded, _state), do: false

  defp forced_stop_input?("\x03", _decoded), do: true

  defp forced_stop_input?(_data, {:key, %{"ctrlKey" => true, "key" => key}}),
    do: key in ["c", "C"]

  defp forced_stop_input?(_data, {:key, %{"ctrlKey" => "true", "key" => key}}),
    do: key in ["c", "C"]

  defp forced_stop_input?(_data, _decoded), do: false

  defp focused_implicit_captures_decoded_input?({:key, key}, state),
    do: focused_implicit_captures_key?(key, state)

  defp focused_implicit_captures_decoded_input?(_decoded, _state), do: false

  defp focused_implicit_captures_key?(key, state) do
    state.server_pid
    |> Breeze.Server.focused_implicit_metadata()
    |> InputCapture.captures_key?(key)
  catch
    :exit, _reason -> false
  end

  defp maybe_start_theme_probe(%{theme_probe: %{status: :active}} = state, _theme),
    do: state

  defp maybe_start_theme_probe(state, theme) do
    if requested_system_theme?(theme) do
      case ThemeProbe.start_runtime_palette_probe(state.terminal) do
        {:start, key, query} ->
          cancel_theme_probe_timer(state.theme_probe)

          ref = make_ref()
          terminal = Termite.Terminal.write(state.terminal, query)

          timer =
            Process.send_after(
              self(),
              {:theme_probe_timeout, key, ref},
              ThemeProbe.runtime_palette_probe_timeout_ms()
            )

          %{
            state
            | terminal: terminal,
              theme_probe: %{
                key: key,
                ref: ref,
                buffer: "",
                palette: %{},
                timer: timer,
                status: :active,
                finished?: false
              }
          }

        _ ->
          state
      end
    else
      state
    end
  end

  defp requested_system_theme?(theme), do: Breeze.Theme.requested_system?(theme)

  defp consume_theme_probe_reply(%{theme_probe: probe} = state, data) do
    {palette, buffer} = ThemeProbe.merge_runtime_palette_data(probe.buffer, probe.palette, data)

    probe = %{probe | palette: palette, buffer: buffer}

    cond do
      ThemeProbe.runtime_palette_probe_complete?(palette) and
          not Map.get(probe, :finished?, false) ->
        ThemeProbe.finish_runtime_palette_probe(state.terminal, palette)
        start_theme_probe_drain(state, %{probe | finished?: true})

      true ->
        %{state | theme_probe: probe}
    end
  end

  defp start_theme_probe_drain(state, probe) do
    cancel_theme_probe_timer(probe)

    # Keep consuming straggling OSC replies for one more response window. This
    # prevents terminal replies becoming keyboard input without leaving an
    # unsupported runtime probe pending for a full extra second.
    timer =
      Process.send_after(
        self(),
        {:theme_probe_drain_timeout, probe.key, probe.ref},
        ThemeProbe.runtime_palette_probe_timeout_ms()
      )

    %{state | theme_probe: %{probe | status: :draining, timer: timer}}
  end

  defp cancel_theme_probe_timer(%{timer: timer}) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp cancel_theme_probe_timer(_probe), do: :ok

  defp maybe_complete_initial_theme_probe(terminal, theme) do
    if requested_system_theme?(theme) do
      case ThemeProbe.start_runtime_palette_probe(terminal) do
        {:start, _key, query} ->
          terminal = Termite.Terminal.write(terminal, query)

          {palette, deferred_messages} =
            collect_initial_theme_probe_replies(
              terminal.reader,
              System.monotonic_time(:millisecond) +
                ThemeProbe.runtime_palette_probe_timeout_ms(),
              "",
              %{},
              []
            )

          _status = ThemeProbe.finish_runtime_palette_probe(terminal, palette)
          {terminal, deferred_messages}

        _ ->
          {terminal, []}
      end
    else
      {terminal, []}
    end
  end

  defp collect_initial_theme_probe_replies(reader, deadline, buffer, palette, deferred_messages) do
    if ThemeProbe.runtime_palette_probe_complete?(palette) do
      {palette, deferred_messages}
    else
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^reader, {:data, data}} = message when is_binary(data) ->
          if theme_probe_data?(buffer, data) do
            {palette, buffer} = ThemeProbe.merge_runtime_palette_data(buffer, palette, data)

            collect_initial_theme_probe_replies(
              reader,
              deadline,
              buffer,
              palette,
              deferred_messages
            )
          else
            collect_initial_theme_probe_replies(
              reader,
              deadline,
              buffer,
              palette,
              [message | deferred_messages]
            )
          end

        message ->
          collect_initial_theme_probe_replies(
            reader,
            deadline,
            buffer,
            palette,
            [message | deferred_messages]
          )
      after
        timeout ->
          {palette, deferred_messages}
      end
    end
  end

  defp enable_mouse(terminal, false), do: terminal
  defp enable_mouse(terminal, nil), do: terminal
  defp enable_mouse(terminal, true), do: Termite.Screen.enable_mouse(terminal)

  defp enable_mouse(terminal, opts) when is_list(opts),
    do: Termite.Screen.enable_mouse(terminal, opts)

  defp build_terminal(opts) do
    case Keyword.get(opts, :terminal) do
      %Termite.Terminal{} = terminal ->
        %TerminalStart{terminal: terminal}

      nil ->
        started = %{start_terminal(opts) | owned?: true}

        iex_shell_proxy =
          try do
            maybe_replace_iex_shell_reader(started.terminal, opts)
          catch
            kind, reason ->
              stacktrace = __STACKTRACE__
              release_terminal_start(started)
              :erlang.raise(kind, reason, stacktrace)
          end

        started = %{started | iex_shell_proxy: iex_shell_proxy}

        try do
          %{started | terminal: Termite.Terminal.resize(started.terminal)}
        catch
          kind, reason ->
            stacktrace = __STACKTRACE__
            release_terminal_start(started)
            :erlang.raise(kind, reason, stacktrace)
        end
    end
  end

  # No screen mode has been enabled at these early failure boundaries. Release
  # only resources this startup created; a supplied terminal remains borrowed.
  defp register_terminal_cleanup(started, opts) do
    try do
      TerminalCleanup.register(started.terminal, opts)
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        release_terminal_start(started)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp release_terminal_start(started) do
    try do
      if started.owned?, do: Termite.Terminal.stop(started.terminal)
    after
      IExShellProxy.stop(started.iex_shell_proxy)
      SilentGroupLeader.stop(started.silent_group_leader)
    end
  end

  defp start_terminal(opts) do
    terminal_opts = Keyword.get(opts, :terminal_opts, [])

    cond do
      pause_iex?(opts) and not Keyword.has_key?(terminal_opts, :adapter) and
          IExShellProxy.io_device?() ->
        terminal_opts =
          Keyword.merge(terminal_opts, adapter: IODevice, device: Process.group_leader())

        %TerminalStart{terminal: Termite.Terminal.start(terminal_opts)}

      pause_iex?(opts) and iex_started?() ->
        start_terminal_with_silent_group_leader(terminal_opts)

      true ->
        %TerminalStart{terminal: Termite.Terminal.start(terminal_opts)}
    end
  end

  defp maybe_put_iex_terminal_size_override(opts) do
    if pause_iex?(opts) and iex_started?() do
      # IEx keeps the physical bottom row for prompt editing after a resize.
      # Let Breeze render inside the rows that remain stable while IEx is paused.
      put_internal_new(opts, :terminal_size_override, &reserve_iex_prompt_row/1)
    else
      opts
    end
  end

  defp reserve_iex_prompt_row(%{height: height} = size) when is_integer(height) do
    %{size | height: max(height - 1, 1)}
  end

  defp reserve_iex_prompt_row(size), do: size

  defp start_terminal_with_silent_group_leader(terminal_opts) do
    original_group_leader = Process.group_leader()

    {:ok, silent_group_leader} = SilentGroupLeader.start_link()

    try do
      Process.group_leader(self(), silent_group_leader)

      terminal = Termite.Terminal.start(terminal_opts)
      maybe_restore_target_shell_input_mode(terminal, original_group_leader)

      %TerminalStart{
        terminal: terminal,
        silent_group_leader: silent_group_leader
      }
    after
      Process.group_leader(self(), original_group_leader)
    end
  end

  defp maybe_restore_target_shell_input_mode(
         %Termite.Terminal{adapter: {Termite.Terminal.Shell, _shell}},
         group_leader
       )
       when node(group_leader) != node() do
    set_target_shell_input_mode(:cooked)
  end

  defp maybe_restore_target_shell_input_mode(_terminal, _group_leader), do: :ok

  defp set_target_shell_input_mode(mode) when mode in [:raw, :cooked] do
    case :shell.start_interactive({:noshell, mode}) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp maybe_replace_iex_shell_reader(
         %Termite.Terminal{adapter: {IODevice, _}} = terminal,
         _opts
       ),
       do: %{io_device: terminal}

  defp maybe_replace_iex_shell_reader(
         %Termite.Terminal{
           adapter: {Termite.Terminal.Shell, %Termite.Terminal.Shell{pid: shell_pid}}
         },
         opts
       ) do
    if pause_iex?(opts) and iex_started?() do
      replace_shell_reader(shell_pid)
    end
  end

  defp maybe_replace_iex_shell_reader(_terminal, _opts), do: nil

  defp replace_shell_reader(shell_pid) when is_pid(shell_pid) do
    with %{reader: reader} when is_pid(reader) <- :sys.get_state(shell_pid),
         true <- Process.alive?(reader),
         {:ok, iex_shell_proxy} <- IExShellProxy.start_link(shell_pid) do
      unlink_shell_reader(shell_pid, reader)
      Process.exit(reader, :kill)
      iex_shell_proxy
    else
      _ -> nil
    end
  catch
    _kind, _reason -> nil
  end

  defp unlink_shell_reader(shell_pid, reader) do
    :sys.replace_state(shell_pid, fn state ->
      Process.unlink(reader)
      state
    end)

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp pause_iex?(opts), do: internal_get(opts, :pause_iex, false)

  defp internal_get(opts, key, default) do
    internal = keyword_group(opts, :internal)

    if Keyword.has_key?(internal, key) do
      Keyword.fetch!(internal, key)
    else
      default
    end
  end

  defp put_internal_new(opts, key, value) do
    if Keyword.has_key?(keyword_group(opts, :internal), key) do
      opts
    else
      Keyword.put(opts, :internal, Keyword.put(keyword_group(opts, :internal), key, value))
    end
  end

  defp put_internal(opts, key, value) do
    Keyword.put(opts, :internal, Keyword.put(keyword_group(opts, :internal), key, value))
  end

  defp keyword_group(opts, key) do
    case Keyword.get(opts, key, []) do
      group when is_list(group) -> group
      _other -> []
    end
  end

  defp iex_started? do
    Code.ensure_loaded?(IEx) and function_exported?(IEx, :started?, 0) and IEx.started?()
  end

  defp stop(state) do
    stop_server(state.server_pid)
    state = restore_terminal(state)

    {:stop, :normal, state}
  end

  defp session_exit_reason(reason) when reason in [:normal, :shutdown], do: :normal
  defp session_exit_reason({:shutdown, _reason}), do: :normal
  defp session_exit_reason(reason), do: reason

  defp restore_terminal(%{terminal_restored?: true} = state), do: state

  defp restore_terminal(state) do
    case TerminalCleanup.restore(state.terminal_cleanup, state.terminal) do
      {:restored, terminal} ->
        %{state | terminal: terminal, terminal_restored?: true}

      :already_restored ->
        %{state | terminal_restored?: true}
    end
  end

  defp stop_server(server_pid) do
    Process.unlink(server_pid)
    if Process.alive?(server_pid), do: GenServer.stop(server_pid, :shutdown)
    :ok
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, {GenServer, :stop, _args}} -> :ok
  end

  defp cleanup_failed_start(
         terminal,
         terminal_cleanup,
         child_view_supervisor,
         remote_inspector_supervisor,
         iex_shell_proxy,
         silent_group_leader
       ) do
    Breeze.RemoteInspector.Supervisor.stop(remote_inspector_supervisor)
    Breeze.ChildViewSupervisor.stop(child_view_supervisor)

    try do
      _ = TerminalCleanup.restore(terminal_cleanup, terminal)
    after
      IExShellProxy.stop(iex_shell_proxy)
      SilentGroupLeader.stop(silent_group_leader)
    end

    :ok
  end

  defp enable_enhanced_keyboard(terminal) do
    Termite.Screen.enable_enhanced_keyboard(terminal)
  end

  defp decode_input(raw_key) do
    Breeze.Input.decode(raw_key)
  end

  defp normalize_key_event(%{"key" => _} = event), do: event
  defp normalize_key_event(key), do: %{"key" => key}
end
