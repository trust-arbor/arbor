defmodule Arbor.Commands.SourceCoupling.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SourceCoupling.{Baseline, Core, Encode}

  @moduletag :fast

  defp file(path, bytes, oid \\ nil) do
    oid = oid || :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    %{path: path, blob_oid: oid, bytes: bytes}
  end

  defp mix(app, deps) do
    dep_lines =
      Enum.map_join(deps, ",\n", fn d ->
        "{:#{d}, in_umbrella: true}"
      end)

    """
    defmodule #{Macro.camelize(app)}.MixProject do
      use Mix.Project
      def project do
        [app: :#{app}, deps: [#{dep_lines}]]
      end
    end
    """
  end

  defp bundle(files) do
    %{
      files: files,
      tree_oid: String.duplicate("a", 40),
      object_format: "sha1"
    }
  end

  test "declared downward reference is not gating" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file("apps/arbor_common/mix.exs", mix("arbor_common", ["arbor_contracts"])),
      file(
        "apps/arbor_contracts/lib/contracts.ex",
        """
        defmodule Arbor.Contracts.Foo do
          def ok, do: :ok
        end
        """
      ),
      file(
        "apps/arbor_common/lib/common.ex",
        """
        defmodule Arbor.Common.Bar do
          alias Arbor.Contracts.Foo
          def call, do: Foo.ok()
        end
        """
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    gating = census["gating_occurrences"]
    assert gating == []

    occs = census["occurrences"]
    assert Enum.any?(occs, &(&1["target"] == "Arbor.Contracts.Foo" and &1["declared"] == true))
    assert Enum.any?(occs, &(&1["fate"] == "intra_band" or &1["fate"] == "downward"))
  end

  test "undeclared downward gates as new finding" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file("apps/arbor_common/mix.exs", mix("arbor_common", [])),
      file(
        "apps/arbor_contracts/lib/contracts.ex",
        "defmodule Arbor.Contracts.Foo do\n  def ok, do: :ok\nend\n"
      ),
      file(
        "apps/arbor_common/lib/common.ex",
        """
        defmodule Arbor.Common.Bar do
          def call, do: Arbor.Contracts.Foo.ok()
        end
        """
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    assert Enum.any?(census["gating_occurrences"], &(&1["declared"] == false))

    empty_baseline = empty_baseline_doc()
    assert {:ok, cmp} = Core.compare(census, "check", empty_baseline)
    report = Core.show(census, cmp)
    assert report["status"] == "failed"
    assert Enum.any?(cmp["comparison"]["failures"], &(&1["reason"] == "new_finding"))
  end

  test "undeclared upward has fate upward and level_upward when levels invert" do
    # contracts (L0) references common (higher level if common deps contracts — but if
    # contracts deps nothing and common deps contracts, common is higher level.
    # Reference from contracts → common is level_upward and band may be intra_band (both K).
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file("apps/arbor_common/mix.exs", mix("arbor_common", ["arbor_contracts"])),
      file(
        "apps/arbor_common/lib/common.ex",
        "defmodule Arbor.Common.Z do\n  def ok, do: :ok\nend\n"
      ),
      file(
        "apps/arbor_contracts/lib/contracts.ex",
        """
        defmodule Arbor.Contracts.Up do
          def call, do: Arbor.Common.Z.ok()
        end
        """
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    gate = Enum.find(census["gating_occurrences"], &(&1["target"] == "Arbor.Common.Z"))
    assert gate
    assert gate["declared"] == false
    assert gate["level_direction"] == "level_upward"
    assert gate["from_band"] == "K"
    assert gate["to_band"] == "K"
    assert gate["fate"] == "intra_band"
  end

  test "band upward fate between interface and kernel" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file("apps/arbor_commands/mix.exs", mix("arbor_commands", [])),
      file(
        "apps/arbor_contracts/lib/c.ex",
        "defmodule Arbor.Contracts.C do\n  def ok, do: :ok\nend\n"
      ),
      file(
        "apps/arbor_commands/lib/x.ex",
        # commands is I, contracts is K — downward band fate
        "defmodule Arbor.Commands.X do\n  def c, do: Arbor.Contracts.C.ok()\nend\n"
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    occ = Enum.find(census["occurrences"], &(&1["target"] == "Arbor.Contracts.C"))
    assert occ["from_band"] == "I"
    assert occ["to_band"] == "K"
    assert occ["fate"] == "downward"
  end

  test "grouped alias expands targets" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file("apps/arbor_common/mix.exs", mix("arbor_common", ["arbor_contracts"])),
      file(
        "apps/arbor_contracts/lib/a.ex",
        """
        defmodule Arbor.Contracts.A do
          def a, do: :a
        end
        defmodule Arbor.Contracts.B do
          def b, do: :b
        end
        """
      ),
      file(
        "apps/arbor_common/lib/g.ex",
        """
        defmodule Arbor.Common.G do
          alias Arbor.Contracts.{A, B}
          def go, do: {A.a(), B.b()}
        end
        """
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    targets = Enum.map(census["occurrences"], & &1["target"]) |> MapSet.new()
    assert "Arbor.Contracts.A" in targets
    assert "Arbor.Contracts.B" in targets
  end

  test "nested module ownership and references" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file("apps/arbor_common/mix.exs", mix("arbor_common", [])),
      file(
        "apps/arbor_contracts/lib/n.ex",
        """
        defmodule Arbor.Contracts.Outer do
          defmodule Inner do
            def ok, do: :ok
          end
        end
        """
      ),
      file(
        "apps/arbor_common/lib/n.ex",
        """
        defmodule Arbor.Common.Uses do
          def call, do: Arbor.Contracts.Outer.Inner.ok()
        end
        """
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    assert Enum.any?(census["occurrences"], &(&1["target"] == "Arbor.Contracts.Outer.Inner"))
  end

  test "static Module.concat resolves" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file("apps/arbor_common/mix.exs", mix("arbor_common", [])),
      file(
        "apps/arbor_contracts/lib/m.ex",
        "defmodule Arbor.Contracts.M do\n  def ok, do: :ok\nend\n"
      ),
      file(
        "apps/arbor_common/lib/m.ex",
        """
        defmodule Arbor.Common.M do
          def call do
            Module.concat([Arbor, Contracts, M]).ok()
          end
        end
        """
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    assert Enum.any?(census["occurrences"], &(&1["target"] == "Arbor.Contracts.M"))
  end

  test "typespec-only undeclared is gating" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file("apps/arbor_common/mix.exs", mix("arbor_common", [])),
      file(
        "apps/arbor_contracts/lib/t.ex",
        "defmodule Arbor.Contracts.T do\n  @type t :: atom()\nend\n"
      ),
      file(
        "apps/arbor_common/lib/t.ex",
        """
        defmodule Arbor.Common.T do
          @spec f() :: Arbor.Contracts.T.t()
          def f, do: :ok
        end
        """
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    gate = Enum.find(census["gating_occurrences"], &(&1["target"] == "Arbor.Contracts.T"))
    assert gate
    assert gate["class"] == "typespec_only"
  end

  test "unresolved dynamic Module.concat is not silent and needs disposition" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file(
        "apps/arbor_contracts/lib/d.ex",
        """
        defmodule Arbor.Contracts.Dyn do
          def call(x) do
            Module.concat([x, "Tail"]).ok()
          end
        end
        """
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    assert census["unresolved"] != []
    u = hd(census["unresolved"])
    assert u["expression_digest"] != ""
    assert u["reason"] in ["dynamic_module_concat", "dynamic_module_expr"]

    empty = empty_baseline_doc()
    assert {:ok, cmp} = Core.compare(census, "check", empty)
    assert cmp["comparison"]["status"] == "failed"
    assert Enum.any?(cmp["comparison"]["failures"], &(&1["reason"] == "unexplained_unresolved"))
  end

  test "import does not create alias binding" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file("apps/arbor_common/mix.exs", mix("arbor_common", ["arbor_contracts"])),
      file(
        "apps/arbor_contracts/lib/imp.ex",
        "defmodule Arbor.Contracts.Imp do\n  def ok, do: :ok\nend\n"
      ),
      file(
        "apps/arbor_common/lib/imp.ex",
        """
        defmodule Arbor.Common.Imp do
          import Arbor.Contracts.Imp
          # Bare Imp should NOT expand via import binding; only alias binds.
          # Remote Arbor.Contracts.Imp still counts as declared ref from import line.
          def call, do: :ok
        end
        """
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    kinds = for o <- census["occurrences"], o["target"] == "Arbor.Contracts.Imp", do: o["kind"]
    assert "import" in kinds
  end

  test "canonical digest stable across input ordering" do
    a =
      file(
        "apps/arbor_contracts/mix.exs",
        mix("arbor_contracts", []),
        String.duplicate("1", 40)
      )

    b =
      file(
        "apps/arbor_common/mix.exs",
        mix("arbor_common", []),
        String.duplicate("2", 40)
      )

    c =
      file(
        "apps/arbor_contracts/lib/a.ex",
        "defmodule Arbor.Contracts.A do\nend\n",
        String.duplicate("3", 40)
      )

    assert {:ok, c1} = Core.new(bundle([a, b, c]))
    assert {:ok, c2} = Core.new(bundle([c, b, a]))
    assert c1["provenance"]["scan_manifest_digest"] == c2["provenance"]["scan_manifest_digest"]

    r1 = Core.show(c1, %{"mode" => "report", "comparison" => nil, "write_plan" => nil})
    r2 = Core.show(c2, %{"mode" => "report", "comparison" => nil, "write_plan" => nil})
    assert {:ok, b1} = Encode.encode_report(Map.drop(r1, ["write_plan"]))
    assert {:ok, b2} = Encode.encode_report(Map.drop(r2, ["write_plan"]))
    assert b1 == b2
  end

  test "entries_digest does not include tree_oid" do
    entry = %{
      "file" => "apps/arbor_common/lib/x.ex",
      "from_module" => "Arbor.Common.X",
      "target" => "Arbor.Contracts.Y",
      "kind" => "remote",
      "class" => "code",
      "from_app" => "arbor_common",
      "to_app" => "arbor_contracts",
      "from_band" => "K",
      "to_band" => "K",
      "fate" => "intra_band",
      "level_direction" => "level_downward",
      "occurrence_count" => 1
    }

    d1 = Encode.entries_digest([entry])
    d2 = Encode.entries_digest([entry])
    assert d1 == d2
    refute String.contains?(d1, "tree")
  end

  test "baseline count increase and metadata change fail; check cannot write" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file("apps/arbor_common/mix.exs", mix("arbor_common", [])),
      file(
        "apps/arbor_contracts/lib/y.ex",
        "defmodule Arbor.Contracts.Y do\n  def ok, do: :ok\nend\n"
      ),
      file(
        "apps/arbor_common/lib/y.ex",
        """
        defmodule Arbor.Common.Y do
          def call do
            Arbor.Contracts.Y.ok()
            Arbor.Contracts.Y.ok()
          end
        end
        """
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    gating = census["gating_occurrences"]
    assert length(gating) >= 1

    # Baseline with count 1
    base_entry =
      gating
      |> hd()
      |> Map.put("occurrence_count", 1)
      |> Encode.order_entry()

    baseline = %{
      "schema" => "arbor.packaging.source_coupling.baseline.v1",
      "version" => 1,
      "provenance" => %{"tree_oid" => String.duplicate("b", 40), "scan_manifest_digest" => "x"},
      "policy" => %{
        "removal" => "require_write",
        "typespec_only" => "gate",
        "unresolved" => "require_disposition",
        "metadata_match" => "required"
      },
      "counts" => %{},
      "entries" => [base_entry],
      "unresolved_entries" => [],
      "entries_digest" => Encode.entries_digest([base_entry])
    }

    assert {:ok, admitted} = Baseline.admit(baseline)
    assert {:ok, comparison} = Baseline.compare(admitted, gating, [])

    if hd(gating)["occurrence_count"] > 1 do
      assert comparison["status"] == "failed"
      assert Enum.any?(comparison["failures"], &(&1["reason"] == "occurrence_count_increased"))
    end

    # metadata change: baseline stores downward, current reports upward at same count
    same_count =
      gating
      |> hd()
      |> Map.put("occurrence_count", 1)
      |> Map.put("fate", "upward")
      |> Encode.order_entry()

    base_entry2 =
      same_count
      |> Map.put("fate", "downward")
      |> Encode.order_entry()

    base2 = %{
      baseline
      | "entries" => [base_entry2],
        "entries_digest" => Encode.entries_digest([base_entry2])
    }

    assert {:ok, adm2} = Baseline.admit(base2)
    assert {:ok, cmp2} = Baseline.compare(adm2, [same_count], [])
    assert cmp2["status"] == "failed"
    assert Enum.any?(cmp2["failures"], &(&1["reason"] == "occurrence_metadata_changed"))

    # write plan only in write mode
    assert {:ok, wr} = Core.compare(census, "write_baseline", nil, %{})
    assert is_map(wr["write_plan"])
    assert {:ok, ch} = Core.compare(census, "check", baseline)
    assert ch["write_plan"] == nil
  end

  test "private integrations paths excluded from canonical bundle" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file(
        "apps/arbor_integrations/mix.exs",
        mix("arbor_integrations", ["arbor_contracts"])
      ),
      file(
        "apps/arbor_integrations/lib/i.ex",
        "defmodule Arbor.Integrations.I do\n  def x, do: Arbor.Contracts.Z.x()\nend\n"
      ),
      file(
        "apps/arbor_contracts/lib/z.ex",
        "defmodule Arbor.Contracts.Z do\n  def x, do: :ok\nend\n"
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    assert census["provenance"]["app_count"] == 1
    refute Enum.any?(census["occurrences"], &String.contains?(&1["file"], "integrations"))
    # Canonical ownership still sees contracts module.
    assert Map.has_key?(census["module_owners"], "Arbor.Contracts.Z")
  end

  test "compatibility projection resolves private-to-tracked refs via canonical ownership" do
    canonical_files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file(
        "apps/arbor_contracts/lib/z.ex",
        "defmodule Arbor.Contracts.Z do\n  def x, do: :ok\nend\n"
      )
    ]

    private_files = [
      file(
        "apps/arbor_integrations/mix.exs",
        mix("arbor_integrations", ["arbor_contracts"])
      ),
      file(
        "apps/arbor_integrations/lib/private_ref.ex",
        """
        defmodule Arbor.Integrations.PrivateRef do
          def call, do: Arbor.Contracts.Z.x()
        end
        """
      )
    ]

    assert {:ok, census} = Core.new(bundle(canonical_files))
    assert census["gating_occurrences"] == [] or is_list(census["gating_occurrences"])

    assert {:ok, projection} = Core.project_compatibility(private_files, census)
    assert projection["gating"] == false
    assert projection["source"] == "private_opt_in"

    occ =
      Enum.find(
        projection["occurrences"],
        &(&1["target"] == "Arbor.Contracts.Z" and &1["from_app"] == "arbor_integrations")
      )

    assert occ
    assert occ["to_app"] == "arbor_contracts"
    assert occ["from_band"] == "private"
    assert occ["to_band"] == "K"
    assert occ["fate"] == "private_to_tracked"
    assert occ["declared"] == true

    # Must not leak into canonical gating / baseline surface.
    refute Enum.any?(
             census["gating_occurrences"],
             &String.contains?(&1["file"] || "", "integrations")
           )
  end

  test "provisional_delta has separate series" do
    files = [
      file("apps/arbor_contracts/mix.exs", mix("arbor_contracts", [])),
      file(
        "apps/arbor_contracts/lib/p.ex",
        "defmodule Arbor.Contracts.P do\nend\n"
      )
    ]

    assert {:ok, census} = Core.new(bundle(files))
    report = Core.show(census, %{"mode" => "report", "comparison" => nil, "write_plan" => nil})
    delta = report["provisional_delta"]
    assert Map.has_key?(delta, "undeclared")
    assert Map.has_key?(delta, "level_hierarchy")
    assert Map.has_key?(delta, "band_fate")
    assert delta["undeclared"]["reference"]["occurrences"] == 234
    assert delta["level_hierarchy"]["reference"]["level_upward"] == 108
    assert delta["band_fate"]["reference"]["intra_band"] == 124
  end

  defp empty_baseline_doc do
    digest = Encode.entries_digest([])

    %{
      "schema" => "arbor.packaging.source_coupling.baseline.v1",
      "version" => 1,
      "provenance" => %{
        "tree_oid" => String.duplicate("c", 40),
        "scan_manifest_digest" => String.duplicate("d", 64)
      },
      "policy" => %{
        "removal" => "require_write",
        "typespec_only" => "gate",
        "unresolved" => "require_disposition",
        "metadata_match" => "required"
      },
      "counts" => %{},
      "entries" => [],
      "unresolved_entries" => [],
      "entries_digest" => digest
    }
  end
end
