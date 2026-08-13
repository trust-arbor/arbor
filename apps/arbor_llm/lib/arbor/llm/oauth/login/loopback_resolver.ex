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
    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(~c"localhost", family) do
          {:ok, values} -> values
          {:error, _reason} -> []
        end
      end)

    validate(addresses)
  end

  defp loopback?({127, _b, _c, _d}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_address), do: false
end
