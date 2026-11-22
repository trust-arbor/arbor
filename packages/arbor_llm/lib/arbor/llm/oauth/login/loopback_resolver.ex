defmodule Arbor.LLM.OAuth.Login.LoopbackResolver do
  @moduledoc false

  @timeout_ms 1_000
  @max_addresses 4

  @spec resolve() :: {:ok, [:inet.ip_address()]} | {:error, atom()}
  def resolve do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            resolve_families()
          catch
            _, _ -> {:error, :localhost_resolution_failed}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :localhost_resolution_failed}
    after
      @timeout_ms ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^monitor, :process, ^pid, _} -> :ok)
        {:error, :localhost_resolution_timeout}
    end
  end

  @doc false
  @spec validate(term()) :: {:ok, [:inet.ip_address()]} | {:error, atom()}
  def validate(addresses) when is_list(addresses) do
    unique = Enum.uniq(addresses)

    cond do
      unique == [] -> {:error, :localhost_resolution_failed}
      length(unique) > @max_addresses -> {:error, :localhost_resolution_invalid}
      not Enum.all?(unique, &loopback?/1) -> {:error, :localhost_resolution_invalid}
      true -> {:ok, unique}
    end
  end

  def validate(_addresses), do: {:error, :localhost_resolution_invalid}

  defp resolve_families do
    combine_family_results(
      :inet.getaddrs(~c"localhost", :inet),
      :inet.getaddrs(~c"localhost", :inet6)
    )
  end

  @doc false
  @spec combine_family_results(term(), term()) ::
          {:ok, [:inet.ip_address()]} | {:error, atom()}
  def combine_family_results(ipv4_result, ipv6_result) do
    with {:ok, ipv4} <- family_addresses(ipv4_result),
         {:ok, ipv6} <- family_addresses(ipv6_result) do
      validate(ipv4 ++ ipv6)
    end
  end

  defp family_addresses({:ok, addresses}) when is_list(addresses), do: {:ok, addresses}

  defp family_addresses({:error, reason}) when reason in [:eafnosupport, :enotsup],
    do: {:ok, []}

  defp family_addresses({:error, _reason}), do: {:error, :localhost_resolution_failed}
  defp family_addresses(_result), do: {:error, :localhost_resolution_failed}

  defp loopback?({127, _b, _c, _d}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_address), do: false
end
