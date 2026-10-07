defmodule Arbor.Common.Sanitizers.SSRF.FinchPool do
  @moduledoc false

  @slot_names [
    __MODULE__.Slot0,
    __MODULE__.Slot1,
    __MODULE__.Slot2,
    __MODULE__.Slot3,
    __MODULE__.Slot4,
    __MODULE__.Slot5,
    __MODULE__.Slot6,
    __MODULE__.Slot7
  ]
  @req_name __MODULE__.ReqBoundary
  @max_header_list_size 32_768
  @idle_timeout_ms 1_000
  @retry_interval_ms 5

  @doc false
  @spec req_name() :: atom()
  def req_name, do: @req_name

  @doc false
  @spec with_pool(:inet.ip_address(), String.t(), integer(), (Finch.name() -> result)) ::
          result | {:error, :timeout | {:pool_start_failed, term()}}
        when result: term()
  def with_pool(address, hostname, deadline, fun)
      when is_tuple(address) and is_binary(hostname) and is_integer(deadline) and
             is_function(fun, 1) do
    acquire(address, hostname, deadline, fun)
  end

  @doc false
  @spec stats() :: %{active_slots: non_neg_integer(), capacity: pos_integer()}
  def stats do
    %{
      active_slots: Enum.count(@slot_names, &is_pid(Process.whereis(&1))),
      capacity: length(@slot_names)
    }
  end

  defp acquire(address, hostname, deadline, fun) do
    if remaining_ms(deadline) == 0 do
      {:error, :timeout}
    else
      case start_available_slot(@slot_names, address, hostname, deadline) do
        {:ok, pid, name} ->
          try do
            fun.(name)
          after
            stop_slot(pid, deadline)
          end

        :busy ->
          Process.sleep(min(@retry_interval_ms, remaining_ms(deadline)))
          acquire(address, hostname, deadline, fun)

        {:error, reason} ->
          {:error, {:pool_start_failed, reason}}
      end
    end
  end

  defp start_available_slot([], _address, _hostname, _deadline), do: :busy

  defp start_available_slot([name | names], address, hostname, deadline) do
    timeout = max(min(remaining_ms(deadline), 5_000), 1)
    address_options = if tuple_size(address) == 8, do: [inet6: true, inet4: false], else: []

    options = [
      name: name,
      pools: %{
        default: [
          size: 1,
          count: 1,
          protocols: [:http1],
          conn_opts: [
            hostname: hostname,
            max_header_list_size: @max_header_list_size,
            transport_opts: [timeout: timeout, nodelay: true, keepalive: true] ++ address_options
          ],
          conn_max_idle_time: @idle_timeout_ms,
          pool_max_idle_time: @idle_timeout_ms,
          start_pool_metrics?: false
        ]
      }
    ]

    case Finch.start_link(options) do
      {:ok, pid} ->
        {:ok, pid, name}

      {:error, {:already_started, _pid}} ->
        start_available_slot(names, address, hostname, deadline)

      {:error, {:shutdown, {:failed_to_start_child, _child, {:already_started, _pid}}}} ->
        start_available_slot(names, address, hostname, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_slot(pid, deadline) do
    monitor_ref = Process.monitor(pid)

    stopped =
      if Process.alive?(pid) do
        try do
          Supervisor.stop(pid, :normal, max(min(remaining_ms(deadline), 1_000), 1))
          :normal
        catch
          :exit, _reason ->
            force_stop_slot(pid, monitor_ref)
            :forced
        end
      else
        :normal
      end

    if stopped == :normal, do: await_slot_down(pid, monitor_ref), else: :ok
  end

  defp await_slot_down(pid, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        :ok
    after
      1_000 ->
        force_stop_slot(pid, monitor_ref)
    end
  end

  defp force_stop_slot(pid, monitor_ref) do
    previous_trap_exit = Process.flag(:trap_exit, true)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    end

    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end

    Process.flag(:trap_exit, previous_trap_exit)
    :ok
  end

  defp remaining_ms(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)
end
