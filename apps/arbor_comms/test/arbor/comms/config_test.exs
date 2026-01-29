defmodule Arbor.Comms.ConfigTest do
  use ExUnit.Case, async: true

  alias Arbor.Comms.Config

  describe "channel_enabled?/1" do
    test "returns false when channel not configured" do
      refute Config.channel_enabled?(:nonexistent)
    end

    test "returns false when channel disabled" do
      Application.put_env(:arbor_comms, :test_channel, enabled: false)
      refute Config.channel_enabled?(:test_channel)
    after
      Application.delete_env(:arbor_comms, :test_channel)
    end

    test "returns true when channel enabled" do
      Application.put_env(:arbor_comms, :test_channel, enabled: true)
      assert Config.channel_enabled?(:test_channel)
    after
      Application.delete_env(:arbor_comms, :test_channel)
    end
  end

  describe "channel_config/1" do
    test "returns empty list for unconfigured channel" do
      assert Config.channel_config(:nonexistent) == []
    end

    test "returns config for configured channel" do
      Application.put_env(:arbor_comms, :test_channel, enabled: true, account: "+1234")
      config = Config.channel_config(:test_channel)
      assert config[:enabled] == true
      assert config[:account] == "+1234"
    after
      Application.delete_env(:arbor_comms, :test_channel)
    end
  end

  describe "poll_interval/1" do
    test "returns default interval when not configured" do
      assert Config.poll_interval(:nonexistent) == 60_000
    end

    test "returns configured interval" do
      Application.put_env(:arbor_comms, :test_channel, poll_interval_ms: 5000)
      assert Config.poll_interval(:test_channel) == 5000
    after
      Application.delete_env(:arbor_comms, :test_channel)
    end
  end

  describe "log_dir/1" do
    test "returns default dir for unconfigured channel" do
      assert Config.log_dir(:test) == "/tmp/arbor/test_chat"
    end

    test "returns configured dir" do
      Application.put_env(:arbor_comms, :test_channel, log_dir: "/custom/logs")
      assert Config.log_dir(:test_channel) == "/custom/logs"
    after
      Application.delete_env(:arbor_comms, :test_channel)
    end
  end

  describe "log_retention_days/1" do
    test "returns default retention for unconfigured channel" do
      assert Config.log_retention_days(:nonexistent) == 30
    end

    test "returns configured retention" do
      Application.put_env(:arbor_comms, :test_channel, log_retention_days: 7)
      assert Config.log_retention_days(:test_channel) == 7
    after
      Application.delete_env(:arbor_comms, :test_channel)
    end
  end

  describe "configured_channels/0" do
    test "returns only enabled channels" do
      Application.put_env(:arbor_comms, :signal, enabled: true)
      channels = Config.configured_channels()
      assert :signal in channels
    after
      Application.put_env(:arbor_comms, :signal, enabled: false)
    end
  end
end
