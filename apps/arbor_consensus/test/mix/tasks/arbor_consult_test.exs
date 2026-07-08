defmodule Mix.Tasks.Arbor.ConsultTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Arbor.Consult

  @moduletag :fast

  describe "argument parsing" do
    test "-b aliases to runtime" do
      assert {[runtime: "acp"], ["Question?"], []} =
               Consult.parse_args(["Question?", "-b", "acp"])
    end

    test "--runtime parses as the canonical runtime option" do
      assert {[runtime: "arbor"], ["Question?"], []} =
               Consult.parse_args(["Question?", "--runtime", "arbor"])
    end

    test "legacy --backend cli/api is normalized to runtime values" do
      assert Consult.runtime_option(backend: "cli") == "acp"
      assert Consult.runtime_option(backend: "api") == "arbor"
    end

    test "explicit runtime wins over legacy backend" do
      assert Consult.runtime_option(runtime: "arbor", backend: "cli") == "arbor"
    end
  end
end
