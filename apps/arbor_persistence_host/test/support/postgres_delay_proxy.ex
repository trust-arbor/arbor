defmodule Arbor.Persistence.Test.PostgresDelayProxy do
  @moduledoc false

  use GenServer

  @listen_opts [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]
  @connect_opts [:binary, packet: :raw, active: false]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def port(proxy), do: GenServer.call(proxy, :port)

  def delay_next_commit(proxy, owner, delay_ms)
      when is_pid(owner) and is_integer(delay_ms) and delay_ms > 0 do
    delay_next_match(
      proxy,
      owner,
      delay_ms,
      "COMMIT",
      :postgres_proxy_delaying_commit_reply
    )
  end

  def delay_next_match(proxy, owner, delay_ms, trigger, notification)
      when is_pid(owner) and is_integer(delay_ms) and delay_ms > 0 and is_binary(trigger) and
             byte_size(trigger) > 0 and is_atom(notification) do
    delay_next_match(proxy, owner, delay_ms, trigger, notification, 0)
  end

  def delay_next_match(proxy, owner, delay_ms, trigger, notification, ready_responses_to_skip)
      when is_pid(owner) and is_integer(delay_ms) and delay_ms > 0 and is_binary(trigger) and
             byte_size(trigger) > 0 and is_atom(notification) and
             is_integer(ready_responses_to_skip) and ready_responses_to_skip >= 0 do
    GenServer.call(
      proxy,
      {:delay_next_match, owner, delay_ms, trigger, notification, ready_responses_to_skip}
    )
  end

  @impl GenServer
  def init(opts) do
    upstream_host = Keyword.fetch!(opts, :upstream_host)
    upstream_port = Keyword.fetch!(opts, :upstream_port)
    {:ok, listener} = :gen_tcp.listen(0, @listen_opts)
    {:ok, {_address, port}} = :inet.sockname(listener)
    control = :ets.new(__MODULE__, [:set, :public])
    armed = :atomics.new(1, signed: false)

    acceptor =
      spawn_link(fn ->
        accept_loop(listener, upstream_host, upstream_port, armed, control)
      end)

    {:ok, %{listener: listener, port: port, armed: armed, control: control, acceptor: acceptor}}
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(
        {:delay_next_match, owner, delay_ms, trigger, notification, ready_responses_to_skip},
        _from,
        state
      ) do
    :ets.insert(state.control, [
      {:delay, owner, delay_ms, notification},
      {:trigger, trigger},
      {:ready_responses_to_skip, ready_responses_to_skip}
    ])

    :atomics.put(state.armed, 1, 1)
    {:reply, :ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    :ok
  end

  defp accept_loop(listener, upstream_host, upstream_port, armed, control) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        worker =
          spawn_link(fn ->
            receive do
              {:accepted, ^client} ->
                run_connection(client, upstream_host, upstream_port, armed, control)
            end
          end)

        :ok = :gen_tcp.controlling_process(client, worker)
        send(worker, {:accepted, client})
        accept_loop(listener, upstream_host, upstream_port, armed, control)

      {:error, :closed} ->
        :ok
    end
  end

  defp run_connection(client, upstream_host, upstream_port, armed, control) do
    host = if is_binary(upstream_host), do: String.to_charlist(upstream_host), else: upstream_host

    case :gen_tcp.connect(host, upstream_port, @connect_opts, 5_000) do
      {:ok, upstream} ->
        :ok = :inet.setopts(client, active: :once)
        :ok = :inet.setopts(upstream, active: :once)
        relay(client, upstream, armed, control, <<>>, <<>>)

      {:error, _reason} ->
        :gen_tcp.close(client)
    end
  end

  defp relay(client, upstream, armed, control, client_tail, server_tail) do
    receive do
      {:tcp, ^client, data} ->
        combined = client_tail <> data

        if :atomics.get(armed, 1) == 1 and trigger_matches?(combined, control) do
          :atomics.put(armed, 1, 2)
        end

        :ok = :gen_tcp.send(upstream, data)
        :ok = :inet.setopts(client, active: :once)
        relay(client, upstream, armed, control, tail(combined), server_tail)

      {:tcp, ^upstream, data} ->
        combined = server_tail <> data
        maybe_delay_commit_reply(armed, control, combined)
        :ok = :gen_tcp.send(client, data)
        :ok = :inet.setopts(upstream, active: :once)
        relay(client, upstream, armed, control, client_tail, tail(combined))

      {:tcp_closed, _socket} ->
        close_pair(client, upstream)

      {:tcp_error, _socket, _reason} ->
        close_pair(client, upstream)
    after
      30_000 -> close_pair(client, upstream)
    end
  end

  defp maybe_delay_commit_reply(armed, control, server_data) do
    if :atomics.get(armed, 1) == 2 and ready_for_query?(server_data) do
      case :ets.lookup(control, :ready_responses_to_skip) do
        [{:ready_responses_to_skip, remaining}] when remaining > 0 ->
          :ets.insert(control, {:ready_responses_to_skip, remaining - 1})

        _delay_now ->
          :atomics.put(armed, 1, 3)

          case :ets.lookup(control, :delay) do
            [{:delay, owner, delay_ms, notification}] ->
              send(owner, notification)
              Process.sleep(delay_ms)

            [] ->
              :ok
          end

          :atomics.put(armed, 1, 0)
      end
    end
  end

  defp ready_for_query?(data), do: :binary.match(data, <<?Z, 0, 0, 0, 5>>) != :nomatch

  defp trigger_matches?(data, control) do
    case :ets.lookup(control, :trigger) do
      [{:trigger, trigger}] -> :binary.match(data, trigger) != :nomatch
      [] -> false
    end
  end

  defp tail(data) when byte_size(data) <= 128, do: data
  defp tail(data), do: binary_part(data, byte_size(data) - 128, 128)

  defp close_pair(client, upstream) do
    :gen_tcp.close(client)
    :gen_tcp.close(upstream)
    :ok
  end
end
