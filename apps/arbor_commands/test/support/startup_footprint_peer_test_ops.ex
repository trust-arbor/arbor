defmodule Arbor.Commands.StartupFootprint.PeerTestOps do
  @moduledoc false

  alias Arbor.Commands.StartupFootprint.PeerRunner

  @spec sleep_touch(String.t(), non_neg_integer(), keyword()) :: term()
  def sleep_touch(path, sleep_ms, opts \\ [])

  def sleep_touch(path, sleep_ms, opts)
      when is_binary(path) and is_integer(sleep_ms) and sleep_ms >= 0 and is_list(opts) do
    budget = test_budget(opts)
    announce = test_announce(opts)

    PeerRunner.__test_run_owned__(budget, announce, fn control ->
      if is_pid(announce), do: send(announce, {:peer_work_started, control})

      with {:ok, :ok} <-
             PeerRunner.__test_peer_call__(control, :timer, :sleep, [sleep_ms], :sleep),
           {:ok, :ok} <-
             PeerRunner.__test_peer_call__(
               control,
               :file,
               :write_file,
               [String.to_charlist(path), "late"],
               :write
             ) do
        :ok
      end
    end)
  end

  def sleep_touch(_, _, _), do: {:error, :invalid_test_sleep_touch}

  @spec halt_peer(keyword()) :: term()
  def halt_peer(opts \\ []) when is_list(opts) do
    budget = test_budget(opts)
    announce = test_announce(opts)

    PeerRunner.__test_run_owned__(budget, announce, fn control ->
      if is_pid(announce), do: send(announce, {:peer_work_started, control})
      PeerRunner.__test_peer_call__(control, :erlang, :halt, [1], :halt)
    end)
  end

  @spec consult_app_file(String.t(), atom()) :: {:ok, [atom()]} | {:error, term()}
  def consult_app_file(ebin, app), do: PeerRunner.__test_consult_app_file__(ebin, app)

  defp test_budget(opts) do
    case Keyword.get(opts, :budget_ms) do
      ms when is_integer(ms) and ms > 0 ->
        ms

      _ ->
        timeouts = PeerRunner.timeouts()
        timeouts.boot_ms + timeouts.call_ms + timeouts.shutdown_ms + 5_000
    end
  end

  defp test_announce(opts) do
    case Keyword.get(opts, :announce) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end
end
