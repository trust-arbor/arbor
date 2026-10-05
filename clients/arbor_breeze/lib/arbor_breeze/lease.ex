defmodule ArborBreeze.Lease do
  @moduledoc false

  # A cleanup guardian, not a second conversation owner. A committed human
  # credential must have a monitor outside the Controller so even :kill attempts logout
  # of its owned lease. Only the private cleanup closure carries the close token.
  def own(owner, client, url, session) do
    token = make_ref()

    pid =
      spawn(fn ->
        Process.flag(:sensitive, true)
        ref = Process.monitor(owner)

        receive do
          {:close_lease, ^token, caller, request} ->
            result = logout(client, url, session)
            send(caller, {:lease_closed, self(), request, result})

          {:DOWN, ^ref, :process, ^owner, _} ->
            logout(client, url, session)
        end
      end)

    {pid, fn -> close(pid, token) end}
  end

  defp close(pid, token) do
    ref = Process.monitor(pid)
    request = make_ref()
    send(pid, {:close_lease, token, self(), request})

    receive do
      {:lease_closed, ^pid, ^request, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, _} ->
        {:error, :cleanup_unconfirmed}
    after
      6_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :cleanup_unconfirmed}
    end
  end

  defp logout(client, url, session) do
    case client.logout(url, session) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :unauthorized} -> :ok
      _ -> {:error, :cleanup_unconfirmed}
    end
  rescue
    _ -> {:error, :cleanup_unconfirmed}
  catch
    _, _ -> {:error, :cleanup_unconfirmed}
  end
end
