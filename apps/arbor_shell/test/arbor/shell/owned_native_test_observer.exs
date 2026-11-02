defmodule Arbor.Shell.OwnedNativeTestObserver do
  @moduledoc false
  alias Arbor.Shell.{ExecutionRegistry, ProcessGroup}

  # One private producer only. Call traces carry arity plus the native Port;
  # returns carry only the existing READY group id. No argv/env/state trace.
  def start!(name, caller) do
    Code.ensure_loaded!(ProcessGroup)
    source = ProcessGroup.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()
    expected = Path.expand("../../../lib/arbor/shell/process_group.ex", __DIR__)
    true = String.ends_with?(source, "/apps/arbor_shell/lib/arbor/shell/process_group.ex")
    true = File.read!(source) == File.read!(expected)
    launcher = Path.join(to_string(:code.priv_dir(:arbor_shell)), "arbor_shell_launcher")
    {:ok, %{type: :regular, uid: uid}} = File.lstat(launcher)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.register(self(), observer_name(name))
        session = :trace.session_create(name, self(), [])

        try do
          1 =
            :trace.function(
              session,
              {ProcessGroup, :await_ready, 2},
              [{[:"$1", :_], [], [{:message, :"$1"}, {:return_trace}]}],
              [:local]
            )

          1 = :trace.process(session, caller, true, [:call, :arity, :return_to, :set_on_spawn])
          supervisor = Process.whereis(Arbor.Shell.PortSessionSupervisor)
          true = is_pid(supervisor)
          1 = :trace.process(session, supervisor, true, [:call, :arity, :set_on_spawn])
          send(parent, {:owned_observer_ready, self()})

          loop(%{
            session: session,
            launcher: launcher,
            uid: uid,
            pending: %{},
            parents: %{},
            groups: %{},
            retired: MapSet.new(),
            seen: %{},
            ready: 0,
            errors: [],
            ready_error_categories: [],
            actors: MapSet.new()
          })
        after
          :trace.session_destroy(session)
        end
      end)

    receive do
      {:owned_observer_ready, ^pid} ->
        Process.demonitor(monitor, [:flush])
        pid

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        raise "owned native observer setup failed: #{inspect(reason)}"
    after
      5_000 ->
        # Stop only the exact spawned observer; its normal stop path destroys
        # the private trace session before exit. Kill is a bounded fallback.
        cleanup = make_ref()
        send(pid, {:owned_query, self(), cleanup, :stop})

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        after
          3_000 ->
            Process.exit(pid, :kill)

            receive do
              {:DOWN, ^monitor, :process, ^pid, _} -> :ok
            after
              1_000 -> raise "owned observer timeout cleanup incomplete"
            end
        end

        raise "owned native observer setup timed out"
    end
  end

  # Metadata-only presence of this private native artifact. No argv, signal,
  # READY/group/descendant/never-launched authority or PID baseline exemptions.
  def metadata_launcher_absence_checkpoint! do
    launcher = Path.join(to_string(:code.priv_dir(:arbor_shell)), "arbor_shell_launcher")
    native = launcher_artifact_identity!(launcher)
    basename = Path.basename(launcher)
    true = basename == "arbor_shell_launcher"
    rows = launcher_metadata_rows(nil)
    self_row = Map.fetch!(rows, String.to_integer(System.pid()))
    names = [basename, String.slice(basename, 0, 15), String.slice(basename, 0, 16)]

    candidates =
      Enum.filter(Map.values(rows), fn row ->
        row.euid == self_row.euid and Enum.any?(names, &String.starts_with?(row.ucomm, &1))
      end)

    true = Enum.all?(candidates, &(not maps_private_launcher?(&1, native)))
    true = launcher_artifact_identity!(launcher) == native

    %{
      launcher: launcher,
      native: native,
      euid: self_row.euid,
      self_pid: self_row.pid,
      self_started: self_row.started,
      scope: :metadata_owned_artifact_launcher_absence_only
    }
  end

  def assert_metadata_launcher_absent!(initial) do
    %{scope: :metadata_owned_artifact_launcher_absence_only} = initial
    current = metadata_launcher_absence_checkpoint!()
    true = current == initial
    :ok
  end

  defp launcher_artifact_identity!(launcher) do
    {:ok, %{type: :regular, mode: mode} = stat} = File.lstat(launcher)
    true = Bitwise.band(mode, 0o6000) == 0
    true = is_integer(stat.major_device) and stat.major_device >= 0
    true = is_integer(stat.inode) and stat.inode > 0
    %{type: stat.type, mode: mode, device: stat.major_device, inode: stat.inode}
  end

  defp launcher_metadata_rows(pid) do
    fields = "pid=,uid=,lstart=,ucomm="

    args =
      if is_nil(pid),
        do: ["-axwwc", "-o", fields],
        else: ["-wwc", "-p", Integer.to_string(pid), "-o", fields]

    {output, status} =
      System.cmd("/bin/ps", args, env: [{"LC_ALL", "C"}], stderr_to_stdout: true)

    if status == 1 and not is_nil(pid) and String.trim(output) == "" do
      %{}
    else
      true = status == 0

      rows =
        output
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, rows ->
          [_, pid, euid, started, ucomm] =
            Regex.run(
              ~r/^\s*(\d+)\s+(\d+)\s+(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+\s+\d+)\s+(\S.*)$/,
              line
            )

          pid = String.to_integer(pid)
          true = not Map.has_key?(rows, pid)

          row = %{
            pid: pid,
            euid: String.to_integer(euid),
            started: started |> String.split() |> Enum.join(" "),
            ucomm: String.trim(ucomm)
          }

          Map.put(rows, pid, row)
        end)

      true = map_size(rows) > 0
      true = is_nil(pid) or Map.keys(rows) == [pid]
      rows
    end
  end

  defp maps_private_launcher?(candidate, native) do
    case Map.get(launcher_metadata_rows(candidate.pid), candidate.pid) do
      nil ->
        false

      before ->
        true = before == candidate

        mappings =
          try do
            # lsof always includes p; f/D/i only. Never request c, n or argv.
            {output, 0} =
              System.cmd(
                "/usr/sbin/lsof",
                ["-a", "-p", Integer.to_string(candidate.pid), "-d", "txt", "-FfDi"],
                env: [{"LC_ALL", "C"}],
                stderr_to_stdout: true
              )

            {:ok, launcher_text_mappings!(output, candidate.pid)}
          rescue
            _ -> :unproved
          end

        case Map.get(launcher_metadata_rows(candidate.pid), candidate.pid) do
          nil ->
            false

          after_lookup ->
            true = after_lookup == candidate
            {:ok, mappings} = mappings
            same_inode = Enum.filter(mappings, &(&1.inode == native.inode))
            # An unproved device encoding must never classify our inode outside.
            true = Enum.all?(same_inode, &(&1.device == native.device))
            same_inode != []
        end
    end
  end

  defp launcher_text_mappings!(output, pid) do
    {^pid, entry, mappings} =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce({nil, nil, []}, fn
        "p" <> value, {nil, nil, []} ->
          true = Regex.match?(~r/^[0-9]+$/, value)
          ^pid = String.to_integer(value)
          {pid, nil, []}

        "ftxt", {^pid, entry, mappings} ->
          mappings =
            if is_nil(entry),
              do: mappings,
              else: [complete_launcher_text_mapping!(entry) | mappings]

          {pid, %{}, mappings}

        "D0x" <> value, {^pid, entry, mappings} when is_map(entry) ->
          true = not Map.has_key?(entry, :device)
          true = Regex.match?(~r/^[0-9A-Fa-f]+$/, value)
          {device, ""} = Integer.parse(value, 16)
          true = device >= 0
          {pid, Map.put(entry, :device, device), mappings}

        "i" <> value, {^pid, entry, mappings} when is_map(entry) ->
          true = not Map.has_key?(entry, :inode)
          true = Regex.match?(~r/^[0-9]+$/, value)
          {inode, ""} = Integer.parse(value)
          true = inode > 0
          {pid, Map.put(entry, :inode, inode), mappings}

        _, _ ->
          raise "native text mapping unavailable or malformed"
      end)

    mappings = [complete_launcher_text_mapping!(entry) | mappings]
    mappings
  end

  defp complete_launcher_text_mapping!(entry) do
    true = is_map(entry) and entry |> Map.keys() |> Enum.sort() == [:device, :inode]
    entry
  end

  def processes(name), do: request(name, :processes)
  def expect_ready!(name, minimum), do: request(name, {:expect, minimum})
  def ready?(name, minimum), do: request(name, {:ready?, minimum})
  def kill!(name, pid), do: request(name, {:kill, pid})
  def stop!(name), do: request(name, :stop)

  # Only before a known raw/tracked PortSession can block on send_input.
  def adopt_session!(name, {:execution, id, controller}) do
    entry = :sys.get_state(ExecutionRegistry).executions |> Map.fetch!(id)
    true = entry.controller_pid == controller

    if String.starts_with?(id, "port_") do
      adopt_raw!(name, entry.owner_pid, controller, id)
    else
      request(name, {:watch, entry.owner_pid})
    end
  end

  def adopt_session!(name, pid) when is_pid(pid), do: adopt_raw!(name, pid, self(), nil)

  defp adopt_raw!(name, pid, controller, id) do
    if request(name, {:recorded_actor, pid}) do
      :ok
    else
      state = :sys.get_state(pid)
      true = state.__struct__ == Arbor.Shell.PortSession and state.owner_pid == controller
      true = is_nil(id) or state.id == id
      request(name, {:adopt, pid, state.handle.port, state.handle.group_id})
    end
  end

  defp observer_name(name), do: Module.concat(name, OwnedNativeObserver)

  defp request(name, operation) do
    pid = Process.whereis(observer_name(name))
    true = is_pid(pid)
    reference = make_ref()
    monitor = Process.monitor(pid)
    stop_deadline = System.monotonic_time(:millisecond) + 10_000
    send(pid, {:owned_query, self(), reference, operation})

    receive do
      {:owned_reply, ^reference, result} ->
        if operation == :stop do
          remaining = min(2_000, max(stop_deadline - System.monotonic_time(:millisecond), 0))

          receive do
            {:DOWN, ^monitor, :process, ^pid, :normal} ->
              result

            {:DOWN, ^monitor, :process, ^pid, reason} ->
              raise "owned native observer stop failed: #{inspect(reason)}"
          after
            remaining -> raise "owned native observer stop incomplete"
          end
        else
          Process.demonitor(monitor, [:flush])
          result
        end

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        raise "owned native observation failed: #{inspect(reason)}"
    after
      10_000 -> raise "owned native observation timed out"
    end
  end

  defp loop(state) do
    receive do
      {:owned_query, caller, reference, :stop} ->
        # Cleanup grants no observation credit. The enclosing after destroys
        # the trace session; request/2 waits for this exact observer's DOWN.
        IO.puts(
          :stderr,
          "owned native cleanup only: observation_credit=false trace_drained=false " <>
            diagnostics(state)
        )

        send(caller, {:owned_reply, reference, :ok})

      {:owned_query, caller, reference, operation} ->
        state = barrier(state)

        unless state.errors == [] and map_size(state.pending) == 0 do
          raise "owned native observation incomplete: " <> diagnostics(state)
        end

        {result, state} = query(operation, state)
        send(caller, {:owned_reply, reference, result})
        if operation != :stop, do: loop(state)

      message ->
        loop(event(message, state))
    end
  end

  defp barrier(state) do
    reference = :trace.delivered(state.session, :all)
    drain(state, reference, System.monotonic_time(:millisecond) + 2_000)
  end

  defp drain(state, reference, deadline) do
    receive do
      {:trace_delivered, :all, ^reference} -> settle_pending(state, deadline)
      message -> drain(event(message, state), reference, deadline)
    after
      2_000 -> raise "owned native trace delivery incomplete"
    end
  end

  defp settle_pending(%{pending: pending} = state, deadline) when map_size(pending) > 0 do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message -> settle_pending(event(message, state), deadline)
    after
      remaining -> raise "owned native READY capture incomplete"
    end
  end

  defp settle_pending(state, _deadline), do: state

  defp event({:trace, actor, :call, {ProcessGroup, :await_ready, 2}, port}, state) do
    if owned_actor?(actor, state.session, 4) do
      case port_binding(port, actor, state) do
        {:ok, binding} -> %{state | pending: Map.put(state.pending, actor, binding)}
        :error -> %{state | errors: [:native_port_unavailable | state.errors]}
      end
    else
      if Process.alive?(actor),
        do: state,
        else: %{state | errors: [:actor_ownership_unavailable | state.errors]}
    end
  end

  defp event({:trace, actor, :return_from, {ProcessGroup, :await_ready, 2}, result}, state) do
    state =
      case result do
        {:ok, group} when is_integer(group) and group > 0 ->
          state

        _ ->
          category = ready_error_category(result)
          %{state | ready_error_categories: [category | state.ready_error_categories]}
      end

    case Map.pop(state.pending, actor) do
      {nil, _} ->
        state

      {binding, pending} ->
        state = %{state | pending: pending}

        case result do
          {:ok, group} when is_integer(group) and group > 0 ->
            record(state, actor, binding, group)

          _ ->
            %{state | errors: [:native_ready_unavailable | state.errors]}
        end
    end
  end

  defp event(_message, state), do: state

  # Diagnostic categories never authorize a native binding or an observation.
  defp ready_error_category({:error, :timeout_during_setup}), do: :timeout_during_setup
  defp ready_error_category({:error, :cancelled_during_setup}), do: :cancelled_during_setup
  defp ready_error_category({:error, {:launcher_error, _}}), do: :launcher_error

  defp ready_error_category({:error, {:launcher_exited_before_ready, _}}),
    do: :launcher_exited_before_ready

  defp ready_error_category({:error, {:port_exited, _}}), do: :port_exited
  defp ready_error_category(_), do: :other

  defp diagnostics(state) do
    errors = state.errors |> Enum.uniq() |> Enum.sort()
    categories = state.ready_error_categories |> Enum.uniq() |> Enum.sort()

    "errors=#{inspect(errors)} ready_errors=#{inspect(categories)} " <>
      "pending_count=#{map_size(state.pending)}"
  end

  defp owned_actor?(_actor, _session, 0), do: false

  defp owned_actor?(actor, session, depth) do
    case :trace.info(session, actor, :flags) do
      {:flags, flags} when is_list(flags) ->
        if :return_to in flags do
          true
        else
          case Process.info(actor, :monitors) do
            {:monitors, monitors} ->
              Enum.any?(monitors, fn
                {:process, watched} when is_pid(watched) and node(watched) == node() ->
                  owned_actor?(watched, session, depth - 1)

                _ ->
                  false
              end)

            _ ->
              false
          end
        end

      _ ->
        false
    end
  end

  defp port_binding(port, actor, state) do
    with true <- is_port(port),
         {:connected, ^actor} <- Port.info(port, :connected),
         {:name, name} <- Port.info(port, :name),
         true <- to_string(name) == state.launcher,
         {:os_pid, pid} when is_integer(pid) and pid > 0 <- Port.info(port, :os_pid) do
      identity = Map.get(metadata(), pid)
      true = is_nil(identity) or identity.uid == state.uid
      {:ok, %{pid: pid, port: port, actor: actor, identity: identity}}
    else
      _ -> :error
    end
  end

  defp record(state, actor, binding, group) do
    all = metadata()
    parent = Map.get(all, binding.pid)
    leader = Map.get(all, group)

    verified_leader =
      not is_nil(leader) and same_identity?(binding.identity, parent) and
        leader.ppid == binding.pid and leader.pgid == group and leader.uid == state.uid

    seen = if verified_leader, do: Map.put(state.seen, group, leader), else: state.seen

    %{
      state
      | parents: Map.put(state.parents, binding.pid, binding.identity),
        groups: Map.put(state.groups, group, binding),
        ready: state.ready + 1,
        seen: seen,
        actors: MapSet.put(state.actors, actor)
    }
  end

  defp query({:ready?, minimum}, state), do: {state.ready >= minimum, state}

  defp query({:expect, minimum}, state) do
    true = is_integer(minimum) and minimum >= 0 and state.ready >= minimum
    {:ok, state}
  end

  defp query({:recorded_actor, actor}, state), do: {MapSet.member?(state.actors, actor), state}

  defp query({:watch, pid}, state) do
    true = is_pid(pid) and Process.alive?(pid)
    1 = :trace.process(state.session, pid, true, [:call, :arity, :return_to, :set_on_spawn])
    {:ok, state}
  end

  defp query({:adopt, actor, port, group}, state) do
    {:ok, binding} = port_binding(port, actor, state)
    true = is_integer(group) and group > 0
    {:ok, record(state, actor, binding, group)}
  end

  defp query(:processes, state) do
    {rows, state} = owned_rows(state)

    commands =
      Enum.flat_map(rows, fn row ->
        case System.cmd("/bin/ps", ["-ww", "-p", Integer.to_string(row.pid), "-o", "command="]) do
          {command, 0} ->
            if same_identity?(row, Map.get(metadata(), row.pid)),
              do: [Map.put(row, :command, String.trim(command))],
              else: []

          _ ->
            []
        end
      end)

    {commands, state}
  end

  defp query({:kill, pid}, state) do
    previous = Map.fetch!(state.seen, pid)
    current = Map.get(metadata(), pid)

    if is_nil(current) do
      {{"", 1}, state}
    else
      true = same_identity?(previous, current)
      {System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true), state}
    end
  end

  defp query(:stop, state), do: {:ok, state}

  defp owned_rows(state) do
    all = metadata()
    groups = Map.drop(state.groups, MapSet.to_list(state.retired))

    parents =
      Enum.flat_map(state.parents, fn {pid, identity} ->
        case Map.get(all, pid) do
          nil ->
            []

          row ->
            true = not is_nil(identity)
            if same_identity?(identity, row), do: [row], else: []
        end
      end)

    recorded =
      Enum.filter(Map.values(all), fn row ->
        same_identity?(Map.get(state.seen, row.pid), row)
      end)

    seeds = Map.new(parents ++ recorded, &{&1.pid, &1})
    rows = descendants(seeds, all, state.uid, 32)

    # A numeric PGID alone never authorizes argv: its READY leader identity or
    # a parent chain to an already recorded identity must have been witnessed.
    Enum.each(groups, fn {group, _binding} ->
      Enum.each(Enum.filter(Map.values(all), &(&1.pgid == group)), fn member ->
        true = same_identity?(Map.get(rows, member.pid), member)
      end)
    end)

    live_groups = MapSet.new(Enum.map(Map.values(rows), & &1.pgid))

    retired =
      MapSet.union(state.retired, MapSet.difference(MapSet.new(Map.keys(groups)), live_groups))

    {Map.values(rows), %{state | seen: Map.merge(state.seen, rows), retired: retired}}
  end

  defp descendants(_owned, _all, _uid, 0), do: raise("owned native descendant depth incomplete")

  defp descendants(owned, all, uid, depth) do
    next =
      Enum.reduce(Map.values(all), owned, fn row, selected ->
        parent = Map.get(all, row.ppid)

        if row.uid == uid and same_identity?(Map.get(selected, row.ppid), parent),
          do: Map.put(selected, row.pid, row),
          else: selected
      end)

    if map_size(next) == map_size(owned), do: next, else: descendants(next, all, uid, depth - 1)
  end

  defp same_identity?(left, right) when is_map(left) and is_map(right),
    do: left.pid == right.pid and left.uid == right.uid and left.started == right.started

  defp same_identity?(_left, _right), do: false

  defp metadata do
    fields = "pid=,ppid=,pgid=,uid=,lstart=,comm="

    args =
      if match?({:unix, :darwin}, :os.type()),
        do: ["-axwwc", "-o", fields],
        else: ["-e", "-o", fields]

    {output, 0} = System.cmd("/bin/ps", args, env: [{"LC_ALL", "C"}])

    rows =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, rows ->
        case Regex.run(
               ~r/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\w+\s+\w+\s+\d+\s+\d+:\d+:\d+\s+\d+)\s+(.+)$/,
               line
             ) do
          [_, pid, ppid, pgid, uid, started, comm] ->
            row = %{
              pid: String.to_integer(pid),
              ppid: String.to_integer(ppid),
              pgid: String.to_integer(pgid),
              uid: String.to_integer(uid),
              started: started,
              comm: comm
            }

            Map.put(rows, row.pid, row)

          _ ->
            rows
        end
      end)

    true = Map.has_key?(rows, String.to_integer(System.pid()))
    rows
  end
end
