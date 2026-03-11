defmodule Mix.Tasks.Arbor.AgentTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  describe "module availability" do
    test "task module is loaded" do
      assert {:module, Mix.Tasks.Arbor.Agent} = Code.ensure_loaded(Mix.Tasks.Arbor.Agent)
    end
  end

  describe "option parsing" do
    test "parses --name option" do
      {opts, _, _} =
        OptionParser.parse(["start", "diagnostician", "--name", "TestAgent"],
          strict: [
            name: :string,
            model: :string,
            provider: :string,
            auto_start: :boolean,
            timeout: :integer,
            all: :boolean
          ],
          aliases: [n: :name, m: :model]
        )

      assert opts[:name] == "TestAgent"
    end

    test "parses -n alias for name" do
      {opts, _, _} =
        OptionParser.parse(["start", "diagnostician", "-n", "TestAgent"],
          strict: [
            name: :string,
            model: :string,
            provider: :string,
            auto_start: :boolean,
            timeout: :integer,
            all: :boolean
          ],
          aliases: [n: :name, m: :model]
        )

      assert opts[:name] == "TestAgent"
    end

    test "parses --model and --provider" do
      {opts, _, _} =
        OptionParser.parse(
          ["start", "diagnostician", "--model", "claude-opus", "--provider", "anthropic"],
          strict: [
            name: :string,
            model: :string,
            provider: :string,
            auto_start: :boolean,
            timeout: :integer,
            all: :boolean
          ],
          aliases: [n: :name, m: :model]
        )

      assert opts[:model] == "claude-opus"
      assert opts[:provider] == "anthropic"
    end

    test "parses --timeout for chat" do
      {opts, _, _} =
        OptionParser.parse(["chat", "agent1", "hello", "--timeout", "120"],
          strict: [
            name: :string,
            model: :string,
            provider: :string,
            auto_start: :boolean,
            timeout: :integer,
            all: :boolean
          ],
          aliases: [n: :name, m: :model]
        )

      assert opts[:timeout] == 120
    end

    test "parses --all for list" do
      {opts, _, _} =
        OptionParser.parse(["list", "--all"],
          strict: [
            name: :string,
            model: :string,
            provider: :string,
            auto_start: :boolean,
            timeout: :integer,
            all: :boolean
          ],
          aliases: [n: :name, m: :model]
        )

      assert opts[:all] == true
    end
  end

  describe "command routing" do
    test "separates subcommands from options" do
      {_opts, args, _} =
        OptionParser.parse(["start", "diagnostician", "--name", "Test"],
          strict: [
            name: :string,
            model: :string,
            provider: :string,
            auto_start: :boolean,
            timeout: :integer,
            all: :boolean
          ],
          aliases: [n: :name, m: :model]
        )

      assert args == ["start", "diagnostician"]
    end

    test "chat subcommand includes message in args" do
      {_opts, args, _} =
        OptionParser.parse(["chat", "agent1", "hello world"],
          strict: [
            name: :string,
            model: :string,
            provider: :string,
            auto_start: :boolean,
            timeout: :integer,
            all: :boolean
          ],
          aliases: [n: :name, m: :model]
        )

      assert args == ["chat", "agent1", "hello world"]
    end
  end
end
