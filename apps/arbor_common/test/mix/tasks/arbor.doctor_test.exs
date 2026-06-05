defmodule Mix.Tasks.Arbor.DoctorTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  describe "module availability" do
    test "task module is loaded" do
      assert {:module, Mix.Tasks.Arbor.Doctor} = Code.ensure_loaded(Mix.Tasks.Arbor.Doctor)
    end
  end

  describe "option parsing" do
    test "parses --refresh flag" do
      {opts, _, _} =
        OptionParser.parse(["--refresh"],
          switches: [refresh: :boolean, json: :boolean, verbose: :boolean, configure: :boolean]
        )

      assert opts[:refresh] == true
    end

    test "parses --json flag" do
      {opts, _, _} =
        OptionParser.parse(["--json"],
          switches: [refresh: :boolean, json: :boolean, verbose: :boolean, configure: :boolean]
        )

      assert opts[:json] == true
    end

    test "parses --verbose flag" do
      {opts, _, _} =
        OptionParser.parse(["--verbose"],
          switches: [refresh: :boolean, json: :boolean, verbose: :boolean, configure: :boolean]
        )

      assert opts[:verbose] == true
    end

    test "parses --configure flag" do
      {opts, _, _} =
        OptionParser.parse(["--configure"],
          switches: [refresh: :boolean, json: :boolean, verbose: :boolean, configure: :boolean]
        )

      assert opts[:configure] == true
    end

    test "handles multiple flags" do
      {opts, _, _} =
        OptionParser.parse(["--verbose", "--json"],
          switches: [refresh: :boolean, json: :boolean, verbose: :boolean, configure: :boolean]
        )

      assert opts[:verbose] == true
      assert opts[:json] == true
    end
  end

  describe "provider catalog dependency" do
    test "ProviderCatalog module exists" do
      assert Code.ensure_loaded?(Arbor.LLM.ProviderCatalog)
    end
  end

  describe "runtime-axis flags (Phase 4+ arbor.doctor extension)" do
    @all_switches [
      refresh: :boolean,
      json: :boolean,
      verbose: :boolean,
      configure: :boolean,
      runtimes: :boolean,
      model: :string,
      fallback: :keep,
      runtime: :string
    ]

    test "--runtimes is a boolean flag" do
      {opts, _, _} = OptionParser.parse(["--runtimes"], switches: @all_switches)
      assert opts[:runtimes] == true
    end

    test "--model takes a string argument" do
      {opts, _, _} =
        OptionParser.parse(["--model", "claude-opus-4-6"], switches: @all_switches)

      assert opts[:model] == "claude-opus-4-6"
    end

    test "--fallback can be repeated; each value collected separately" do
      {opts, _, _} =
        OptionParser.parse(
          [
            "--fallback",
            "runtime=acp",
            "--fallback",
            "model=claude-sonnet-4-6,provider=anthropic"
          ],
          switches: @all_switches
        )

      values = for {:fallback, v} <- opts, do: v
      assert values == ["runtime=acp", "model=claude-sonnet-4-6,provider=anthropic"]
    end

    test "--runtime takes a string argument" do
      {opts, _, _} =
        OptionParser.parse(["--runtime", "acp"], switches: @all_switches)

      assert opts[:runtime] == "acp"
    end

    test "all new flags compose with each other" do
      {opts, _, _} =
        OptionParser.parse(
          [
            "--model",
            "claude-opus-4-6",
            "--runtime",
            "arbor",
            "--fallback",
            "runtime=acp",
            "--json"
          ],
          switches: @all_switches
        )

      assert opts[:model] == "claude-opus-4-6"
      assert opts[:runtime] == "arbor"
      assert opts[:json] == true
      assert [_] = for({:fallback, v} <- opts, do: v)
    end

    test "--refresh-models is a boolean flag" do
      switches = Keyword.put(@all_switches, :refresh_models, :boolean)
      {opts, _, _} = OptionParser.parse(["--refresh-models"], switches: switches)
      assert opts[:refresh_models] == true
    end

    test "--refresh-models composes with --json" do
      switches = Keyword.put(@all_switches, :refresh_models, :boolean)

      {opts, _, _} =
        OptionParser.parse(["--refresh-models", "--json"], switches: switches)

      assert opts[:refresh_models] == true
      assert opts[:json] == true
    end
  end
end
