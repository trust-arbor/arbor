defmodule Arbor.Common.LogRedactorPrimaryFilterSecurityRegressionTest do
  @moduledoc """
  Proves secret redaction is a primary Logger filter, not a :default-only
  handler filter.

  A second handler with an empty filter list still must receive a redacted
  event. Installing the walker only on `:default` leaves every other sink
  (this capture handler included) able to log secrets in the clear.
  """

  use ExUnit.Case, async: false
  @moduletag spec: "KSEC-014"
  @moduletag :fast
  @moduletag :security_regression

  require Logger

  @handler_id :arbor_log_redactor_primary_filter_regression

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

      send(owner, {:second_handler_logger_event, event, rendered})
      :ok
    end
  end

  setup do
    remove_capture_handler()

    :ok =
      :logger.add_handler(@handler_id, CaptureHandler, %{
        level: :all,
        filter_default: :log,
        filters: [],
        config: %{owner: self()}
      })

    on_exit(&remove_capture_handler/0)

    refute handler_has_redaction_filter?(@handler_id),
           "this handler must not install its own redaction filter"

    :ok
  end

  test "security regression: a secret logged through a second handler is redacted" do
    secret = "sk-ant-api03-" <> String.duplicate("Y", 32)

    Logger.warning("second-handler-canary token=#{secret}")

    assert_receive {:second_handler_logger_event, event, output}, 1_000
    refute inspect(event) =~ secret
    refute output =~ secret
    assert output =~ "[REDACTED]"
  end

  test "security regression: Bearer abc is redacted through a second handler" do
    # Bare Bearer form — not an "authorization:" assignment, which already
    # redacts short values. This is the {20,} regex gap.
    Logger.warning("proxy request used Bearer abc")

    assert_receive {:second_handler_logger_event, _event, output}, 1_000
    refute output =~ "Bearer abc"
    refute output =~ ~r/\babc\b/
    assert output =~ "[REDACTED]"
  end

  defp handler_has_redaction_filter?(handler_id) do
    with {:ok, %{filters: filters}} <- :logger.get_handler_config(handler_id) do
      Enum.any?(filters, fn
        {:api_key_redaction, _} -> true
        _other -> false
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
