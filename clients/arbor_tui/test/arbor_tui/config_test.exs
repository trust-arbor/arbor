defmodule ArborTui.ConfigTest do
  use ExUnit.Case, async: true

  alias ArborTui.Config

  describe "parse/2" do
    test "key = value lines, comments, blanks, and whitespace trimming" do
      contents = """
      # a comment

        url   =   ws://example:4000
      key = ~/keys/client.arbor.key
      agent=agent_abc
      """

      home = System.user_home!()

      assert Config.parse(contents) == %{
               url: "ws://example:4000",
               key: Path.join(home, "keys/client.arbor.key"),
               agent: "agent_abc"
             }
    end

    test "tolerates unknown keys (dropped)" do
      assert Config.parse("color = blue\nurl = ws://x") == %{url: "ws://x"}
    end

    test "bare ~ expands to the home directory" do
      assert Config.parse("key = ~") == %{key: System.user_home!()}
    end

    test "value may contain = (split on first only)" do
      assert Config.parse("agent = a=b=c") == %{agent: "a=b=c"}
    end

    test "lines without = are ignored" do
      assert Config.parse("garbage line\nurl = ws://y") == %{url: "ws://y"}
    end
  end

  describe "load/1 — missing file" do
    test "missing file yields an empty config" do
      assert Config.load("/nonexistent/path/tui.conf") == %{}
    end
  end

  describe "resolution precedence" do
    test "url: flag > config > env > default" do
      config = %{url: "ws://config"}

      # flag wins over everything
      assert Config.resolve_url([url: "ws://flag"], config) == "ws://flag"

      # config wins over env + default
      System.put_env("ARBOR_GATEWAY_URL", "ws://env")
      assert Config.resolve_url([], config) == "ws://config"

      # env wins over default when no flag/config
      assert Config.resolve_url([], %{}) == "ws://env"
      System.delete_env("ARBOR_GATEWAY_URL")

      # built-in default
      assert Config.resolve_url([], %{}) == "ws://localhost:4000"
    end

    test "key: flag > config > env > default" do
      config = %{key: "/config/key"}

      assert Config.resolve_key([key: "/flag/key"], config) == "/flag/key"
      assert Config.resolve_key([], config) == "/config/key"

      System.put_env("ARBOR_KEY", "/env/key")
      assert Config.resolve_key([], %{}) == "/env/key"
      System.delete_env("ARBOR_KEY")

      assert Config.resolve_key([], %{}) ==
               Path.join(System.user_home!(), ".arbor/client.arbor.key")
    end

    test "agent: flag > config > last_agent (state) > nil" do
      config = %{agent: "agent_config"}
      state = %{last_agent: "agent_last"}

      # flag wins
      assert Config.resolve_agent([agent: "agent_flag"], config, state) == "agent_flag"
      # config wins over last_agent
      assert Config.resolve_agent([], config, state) == "agent_config"
      # last_agent is the auto fallback
      assert Config.resolve_agent([], %{}, state) == "agent_last"
      # nil when nothing is set → start UNATTACHED
      assert Config.resolve_agent([], %{}, %{}) == nil
    end
  end

  describe "state file (tui.state)" do
    setup do
      path = Path.join(System.tmp_dir!(), "arbor_tui_state_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "load_state parses last_agent; missing file → empty", %{path: path} do
      assert Config.load_state(path) == %{}

      Config.save_last_agent("agent_xyz", path)
      assert Config.load_state(path) == %{last_agent: "agent_xyz"}
    end

    test "save_last_agent creates the parent directory", %{path: _} do
      dir =
        Path.join(System.tmp_dir!(), "arbor_tui_state_dir_#{System.unique_integer([:positive])}")

      path = Path.join(dir, "tui.state")
      on_exit(fn -> File.rm_rf(dir) end)

      assert Config.save_last_agent("agent_new", path) == :ok
      assert Config.load_state(path) == %{last_agent: "agent_new"}
    end
  end
end
