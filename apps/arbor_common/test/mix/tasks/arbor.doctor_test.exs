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
      assert Code.ensure_loaded?(Arbor.Orchestrator.UnifiedLLM.ProviderCatalog)
    end
  end
end
