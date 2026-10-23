defmodule Arbor.Common.LogRedactorLoggerBoundarySecurityRegressionTest do
  @moduledoc """
  Exercises redaction through OTP Logger's filter boundary.

  The lower-level walker tests remain useful, but a production regression can
  also come from failing to install or invoke that walker for real Logger
  events. This handler observes the event only after OTP has applied the same
  filter tuple installed as a primary filter by Arbor.Common.Application.
  """

  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-014"

  require Logger

  alias Arbor.Common.LogRedactor

  @handler_id :arbor_log_redactor_boundary_regression

  @moduletag :fast
  @moduletag :security_regression

  defmodule CaptureHandler do
    @moduledoc false
    @behaviour :logger_handler

    @impl true
    def adding_handler(config), do: {:ok, config}

    @impl true
    def changing_config(_set_or_update, _old_config, new_config), do: {:ok, new_config}

    @impl true
    def filter_config(config), do: config

    @impl true
    def removing_handler(_config), do: :ok

    @impl true
    def log(event, %{config: %{owner: owner}}) when is_pid(owner) do
      rendered =
        event
        |> :logger_formatter.format(%{template: [:msg], single_line: true})
        |> IO.chardata_to_string()

      send(owner, {:redacted_logger_event, event, rendered})
      :ok
    end
  end

  setup do
    remove_capture_handler()

    :ok =
      :logger.add_handler(@handler_id, CaptureHandler, %{
        level: :all,
        filter_default: :log,
        filters: [api_key_redaction: {&LogRedactor.filter/2, :log}],
        config: %{owner: self()}
      })

    on_exit(&remove_capture_handler/0)
    :ok
  end

  @tag spec: "KSEC-014"
  test "security regression: real Logger events redact chardata, format args, and metadata" do
    assert primary_filter_uses_redaction?()

    chardata_secret = "xai-" <> String.duplicate("a", 24)
    metadata_secret = "gsk_" <> String.duplicate("b", 24)

    Logger.warning(["token=", chardata_secret], request: %{credential: metadata_secret})

    assert_receive {:redacted_logger_event, chardata_event, chardata_output}, 1_000
    chardata_rendered = inspect(chardata_event)
    refute chardata_rendered =~ chardata_secret
    refute chardata_rendered =~ metadata_secret
    assert chardata_rendered =~ "[REDACTED]"
    assert chardata_output =~ "token=[REDACTED]"

    format_secret = "hf_" <> String.duplicate("c", 24)
    :logger.warning(~c"authorization=~ts", [format_secret])

    assert_receive {:redacted_logger_event, format_event, format_output}, 1_000
    format_rendered = inspect(format_event)
    refute format_rendered =~ format_secret
    assert format_rendered =~ "[REDACTED]"
    assert format_output =~ "authorization=[REDACTED]"
    refute format_output =~ "FORMAT ERROR"
    refute format_output =~ "FORMATTER CRASH"
  end

  defmodule CrashingServer do
    @moduledoc false
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast({:boom, marker}, _state), do: raise("crash marker #{marker}")
  end

  # 2026-10-09: Elixir's primary translator turns a gen_server terminate report
  # into `{:report, flat_map ++ elixir_translation}` plus a report_cb that only
  # prints `:elixir_translation`. The 256-node walk dropped that key from the
  # big flat map, so every supervisor/GenServer crash rendered as `[error] nil`
  # — the Trust boot hang left no exit reason anywhere in the daemon log.
  test "security regression: a real GenServer crash renders its reason, not nil, and stays redacted" do
    marker = "boundary-#{System.unique_integer([:positive])}"
    secret = "sk-ant-api03-" <> String.duplicate("Z", 32)

    big_state =
      1..400
      |> Map.new(fn i -> {"field_#{i}", "value_#{i}"} end)
      |> Map.put(:note, "ANTHROPIC_API_KEY=#{secret}")

    {:ok, pid} = GenServer.start(CrashingServer, big_state)
    ref = Process.monitor(pid)
    GenServer.cast(pid, {:boom, marker})
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

    {event, output} = receive_rendered_containing(marker, 2_000)

    assert match?(%{msg: {:string, _}}, event)
    refute output == "nil"
    assert output =~ "crash marker #{marker}"
    refute inspect(event) =~ secret
    refute output =~ secret
  end

  defp receive_rendered_containing(marker, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    receive_loop = fn loop ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:redacted_logger_event, event, rendered} ->
          if rendered =~ marker, do: {event, rendered}, else: loop.(loop)
      after
        remaining -> flunk("no rendered log event contained #{marker}")
      end
    end

    receive_loop.(receive_loop)
  end

  defp primary_filter_uses_redaction? do
    case :logger.get_primary_config() do
      %{filters: filters} when is_list(filters) ->
        Enum.any?(filters, fn
          {:api_key_redaction, {filter, :log}} when is_function(filter, 2) ->
            :erlang.fun_info(filter, :module) == {:module, LogRedactor} and
              :erlang.fun_info(filter, :name) == {:name, :filter}

          _other ->
            false
        end)

      _other ->
        false
    end
  end

  defp remove_capture_handler do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, {:not_found, @handler_id}} -> :ok
    end
  end
end
