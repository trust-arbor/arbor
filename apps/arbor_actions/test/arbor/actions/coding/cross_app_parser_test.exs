defmodule Arbor.Actions.Coding.CrossApp.ParserTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.CrossApp.Parser

  @moduletag :fast

  test "parses static in_umbrella deps without evaluating source" do
    source = """
    defmodule Alpha.MixProject do
      use Mix.Project

      def project do
        [
          app: :alpha,
          version: "0.1.0",
          deps: deps()
        ]
      end

      defp deps do
        [
          {:beta, in_umbrella: true},
          {:jason, "~> 1.0"},
          {:gamma, path: "../gamma", in_umbrella: true}
        ]
      end
    end
    """

    assert {:ok, app_def} = Parser.parse_mix_exs(source, "alpha")
    assert app_def.dir == "alpha"
    assert app_def.app == "alpha"
    assert app_def.deps == ["beta", "gamma"]
  end

  test "rejects dynamic, malformed, and oversized metadata without creating atoms" do
    novel = "hostile_unseen_app_name_zzzxxyy"

    dynamic_app = """
    defmodule Evil.MixProject do
      use Mix.Project
      def project do
        [app: String.to_atom("#{novel}"), deps: []]
      end
    end
    """

    unknown_atom = """
    defmodule Weird.MixProject do
      use Mix.Project
      def project do
        [app: :#{novel}, deps: []]
      end
    end
    """

    dynamic_deps = """
    defmodule Dyn.MixProject do
      use Mix.Project
      def project, do: [app: :dyn, deps: load_deps()]
      defp load_deps, do: []
    end
    """

    mismatch = """
    defmodule Mismatch.MixProject do
      use Mix.Project
      def project, do: [app: :other, deps: []]
    end
    """

    oversized = String.duplicate("a", 70_000)

    assert {:error, reason_dynamic} = Parser.parse_mix_exs(dynamic_app, "evil")
    assert reason_dynamic in [:dynamic_or_malformed_app, :missing_app, :invalid_app_atom]

    # Quoted with static_atoms_encoder — novel atom becomes non-atom string; fails closed.
    assert {:error, reason_unknown} = Parser.parse_mix_exs(unknown_atom, "weird")

    assert match?({:app_dir_name_mismatch, "weird", _}, reason_unknown) or
             reason_unknown in [:invalid_app_atom, :dynamic_or_malformed_app]

    assert {:error, reason_deps} = Parser.parse_mix_exs(dynamic_deps, "dyn")
    assert reason_deps in [:dynamic_or_malformed_deps, :dynamic_deps_call]

    assert {:error, {:app_dir_name_mismatch, "alpha", "other"}} =
             Parser.parse_mix_exs(mismatch, "alpha")

    assert {:error, :mix_exs_too_large} = Parser.parse_mix_exs(oversized, "alpha")

    # Parser must not materialize the novel identifier as a permanent atom.
    assert_raise ArgumentError, fn ->
      :erlang.binary_to_existing_atom(novel, :utf8)
    end
  end

  test "parse_many fails closed on any malformed entry" do
    good = """
    defmodule Alpha.MixProject do
      use Mix.Project
      def project, do: [app: :alpha, deps: []]
    end
    """

    bad = """
    defmodule Beta.MixProject do
      use Mix.Project
      def project, do: [app: :beta, deps: some_var]
    end
    """

    assert {:error, {:parse_failed, "beta", _}} =
             Parser.parse_many([{"alpha", good}, {"beta", bad}])
  end
end
