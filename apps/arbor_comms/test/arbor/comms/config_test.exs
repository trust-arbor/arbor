defmodule Arbor.Comms.ConfigTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.Config

  describe "channel_enabled?/1" do
    test "returns false when channel not configured" do
      refute Config.channel_enabled?(:nonexistent)
    end

    test "returns false when channel disabled" do
      channel = unique_channel()
      Application.put_env(:arbor_comms, channel, enabled: false)
      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      refute Config.channel_enabled?(channel)
    end

    test "returns true when channel enabled" do
      channel = unique_channel()
      Application.put_env(:arbor_comms, channel, enabled: true)
      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      assert Config.channel_enabled?(channel)
    end
  end

  describe "channel_config/1" do
    test "returns empty list for unconfigured channel" do
      assert Config.channel_config(:nonexistent) == []
    end

    test "returns config for configured channel" do
      channel = unique_channel()
      Application.put_env(:arbor_comms, channel, enabled: true, account: "+1234")
      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      config = Config.channel_config(channel)
      assert config[:enabled] == true
      assert config[:account] == "+1234"
    end
  end

  describe "poll_interval/1" do
    test "returns default interval when not configured" do
      assert Config.poll_interval(:nonexistent) == 60_000
    end

    test "returns configured interval" do
      channel = unique_channel()
      Application.put_env(:arbor_comms, channel, poll_interval_ms: 5000)
      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      assert Config.poll_interval(channel) == 5000
    end
  end

  describe "log_dir/1" do
    test "returns default dir for unconfigured channel" do
      assert Config.log_dir(:test) == "/tmp/arbor/test_chat"
    end

    test "returns configured dir" do
      channel = unique_channel()
      Application.put_env(:arbor_comms, channel, log_dir: "/custom/logs")
      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      assert Config.log_dir(channel) == "/custom/logs"
    end
  end

  describe "log_retention_days/1" do
    test "returns default retention for unconfigured channel" do
      assert Config.log_retention_days(:nonexistent) == 30
    end

    test "returns configured retention" do
      channel = unique_channel()
      Application.put_env(:arbor_comms, channel, log_retention_days: 7)
      on_exit(fn -> Application.delete_env(:arbor_comms, channel) end)

      assert Config.log_retention_days(channel) == 7
    end
  end

  describe "configured_channels/0" do
    test "returns only enabled channels" do
      original_signal = Application.get_env(:arbor_comms, :signal)
      Application.put_env(:arbor_comms, :signal, enabled: true)

      on_exit(fn ->
        if original_signal,
          do: Application.put_env(:arbor_comms, :signal, original_signal),
          else: Application.delete_env(:arbor_comms, :signal)
      end)

      channels = Config.configured_channels()
      assert :signal in channels
    end
  end

  defp unique_channel do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"test_config_#{System.unique_integer([:positive])}"
  end
end
