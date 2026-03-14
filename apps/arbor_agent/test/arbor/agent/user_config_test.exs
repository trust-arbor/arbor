defmodule Arbor.Agent.UserConfigTest do
  use ExUnit.Case, async: false

  alias Arbor.Agent.UserConfig

  @moduletag :fast

  setup do
    # Start with the real store name since UserConfig hardcodes it
    start_supervised!(
      Supervisor.child_spec(
        {Arbor.Persistence.BufferedStore,
         name: :arbor_user_config, backend: nil, collection: "user_config_test"},
        id: :arbor_user_config_test
      )
    )

    :ok
  end

  describe "put/3 and get/2" do
    test "stores and retrieves a setting" do
      assert :ok = UserConfig.put("human_test1", :default_model, "claude-sonnet-4-5-20250514")
      assert "claude-sonnet-4-5-20250514" == UserConfig.get("human_test1", :default_model)
    end

    test "returns nil for unset key" do
      assert nil == UserConfig.get("human_test2", :nonexistent)
    end

    test "overwrites existing value" do
      UserConfig.put("human_test3", :timezone, "UTC")
      UserConfig.put("human_test3", :timezone, "America/Los_Angeles")
      assert "America/Los_Angeles" == UserConfig.get("human_test3", :timezone)
    end

    test "preserves other keys when setting one" do
      UserConfig.put("human_test4", :default_model, "model-a")
      UserConfig.put("human_test4", :timezone, "UTC")
      assert "model-a" == UserConfig.get("human_test4", :default_model)
      assert "UTC" == UserConfig.get("human_test4", :timezone)
    end
  end

  describe "put_many/2" do
    test "stores multiple settings at once" do
      settings = %{default_model: "model-x", default_provider: :anthropic, timezone: "UTC"}
      assert :ok = UserConfig.put_many("human_test5", settings)
      assert "model-x" == UserConfig.get("human_test5", :default_model)
      assert :anthropic == UserConfig.get("human_test5", :default_provider)
      assert "UTC" == UserConfig.get("human_test5", :timezone)
    end

    test "merges with existing config" do
      UserConfig.put("human_test6", :timezone, "UTC")
      UserConfig.put_many("human_test6", %{default_model: "model-y"})
      assert "UTC" == UserConfig.get("human_test6", :timezone)
      assert "model-y" == UserConfig.get("human_test6", :default_model)
    end
  end

  describe "get_effective/3" do
    test "returns user value when set" do
      UserConfig.put("human_test7", :default_model, "user-model")
      assert "user-model" == UserConfig.get_effective("human_test7", :default_model, "fallback")
    end

    test "returns default when nothing set" do
      assert "fallback" == UserConfig.get_effective("human_test8", :default_model, "fallback")
    end

    test "returns nil default when nothing set and no default given" do
      assert nil == UserConfig.get_effective("human_test9", :default_model)
    end
  end

  describe "get_all/1" do
    test "returns all settings as a map" do
      UserConfig.put("human_test10", :default_model, "model-z")
      UserConfig.put("human_test10", :timezone, "UTC")
      config = UserConfig.get_all("human_test10")
      assert config[:default_model] == "model-z"
      assert config[:timezone] == "UTC"
    end

    test "returns empty map for unknown user" do
      assert %{} == UserConfig.get_all("human_unknown")
    end
  end

  describe "delete/2" do
    test "removes a specific setting" do
      UserConfig.put("human_test11", :timezone, "UTC")
      UserConfig.put("human_test11", :default_model, "model")
      assert :ok = UserConfig.delete("human_test11", :timezone)
      assert nil == UserConfig.get("human_test11", :timezone)
      assert "model" == UserConfig.get("human_test11", :default_model)
    end
  end

  describe "delete_all/1" do
    test "removes all settings for a user" do
      UserConfig.put("human_test12", :timezone, "UTC")
      UserConfig.put("human_test12", :default_model, "model")
      assert :ok = UserConfig.delete_all("human_test12")
      assert %{} == UserConfig.get_all("human_test12")
    end
  end

  describe "API key helpers" do
    test "stores and retrieves API keys per provider" do
      UserConfig.put_api_key("human_test13", :anthropic, "sk-ant-test123")
      assert "sk-ant-test123" == UserConfig.get_api_key("human_test13", :anthropic)
    end

    test "returns nil for unset provider" do
      assert nil == UserConfig.get_api_key("human_test14", :openai)
    end

    test "preserves keys for other providers" do
      UserConfig.put_api_key("human_test15", :anthropic, "sk-ant-1")
      UserConfig.put_api_key("human_test15", :openai, "sk-oai-1")
      assert "sk-ant-1" == UserConfig.get_api_key("human_test15", :anthropic)
      assert "sk-oai-1" == UserConfig.get_api_key("human_test15", :openai)
    end
  end

  describe "list_configured_users/0" do
    test "lists users with stored config" do
      UserConfig.put("human_list1", :timezone, "UTC")
      UserConfig.put("human_list2", :timezone, "EST")
      users = UserConfig.list_configured_users()
      assert "human_list1" in users
      assert "human_list2" in users
    end
  end
end
