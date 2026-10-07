defmodule Arbor.Common.LogRedactorLoggerBoundarySecurityRegressionTest do
  @moduledoc """
  Exercises redaction through OTP Logger's handler-filter boundary.

  The lower-level walker tests remain useful, but a production regression can
  also come from failing to install or invoke that walker for real Logger
  events. This handler observes the event only after OTP has applied the same
  filter tuple installed on the default handler by Arbor.Common.Application.
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
    assert default_handler_uses_redaction_filter?()

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

  defp default_handler_uses_redaction_filter? do
    with {:ok, %{filters: filters}} <- :logger.get_handler_config(:default) do
      Enum.any?(filters, fn
        {:api_key_redaction, {filter, :log}} when is_function(filter, 2) ->
          :erlang.fun_info(filter, :module) == {:module, LogRedactor} and
            :erlang.fun_info(filter, :name) == {:name, :filter}

        _other ->
          false
      end)
    else
      _other -> false
    end
  end

  defp remove_capture_handler do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, {:not_found, @handler_id}} -> :ok
    end
  end
end
