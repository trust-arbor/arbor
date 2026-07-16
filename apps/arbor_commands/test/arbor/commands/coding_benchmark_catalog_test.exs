defmodule Arbor.Commands.CodingBenchmark.CatalogTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Commands.CodingBenchmark.Catalog

  @base_commit "0b3d0c8704c7486967bfe4289d22dcb7ebaa81f2"
  @base_tree "0a72282510eb02619f26841e73f1cc23695cb752"
  @target_commit "e19b4f5320bd015030d3ba1b9a6121089ef579f9"
  @target_tree "f671364664e3d6f1cbd12f2906d8cc3ca20ccb8a"

  test "accepts a closed catalog and sorts fixtures by fixture_id" do
    catalog = sample_catalog([alternate_fixture("z-last"), fixture("a-first")])

    assert {:ok, normalized} = Catalog.validate(catalog)
    assert normalized["schema"] == Catalog.schema()
    assert normalized["seed"] == 7
    assert normalized["source_repository_label"] == "arbor"
    assert Enum.map(normalized["fixtures"], & &1["fixture_id"]) == ["a-first", "z-last"]

    assert hd(normalized["fixtures"])["input"] == %{
             "acceptance_criteria" => ["criterion-one"],
             "objective" => "Do the work."
           }
  end

  test "digest is stable for equivalent normalized catalogs" do
    assert {:ok, a} =
             Catalog.validate(sample_catalog([fixture("a-first"), alternate_fixture("z-last")]))

    assert {:ok, b} =
             Catalog.validate(sample_catalog([alternate_fixture("z-last"), fixture("a-first")]))

    assert Catalog.digest(a) == Catalog.digest(b)
  end

  test "rejects unknown catalog keys" do
    catalog = Map.put(sample_catalog([fixture("a-first")]), "module", "Evil")

    assert {:error, %{"field" => "catalog", "reason" => "unknown_field"}} =
             Catalog.validate(catalog)
  end

  test "rejects atom or mixed keys" do
    catalog = %{
      "seed" => 1,
      "source_repository_label" => "arbor",
      "fixtures" => [fixture("a-first")],
      schema: Catalog.schema()
    }

    assert {:error, %{"field" => "catalog", "reason" => "non_string_key"}} =
             Catalog.validate(catalog)
  end

  test "rejects duplicate fixture ids" do
    catalog = sample_catalog([fixture("same"), fixture("same")])

    assert {:error, %{"field" => "catalog.fixtures", "reason" => "duplicate_fixture_id"}} =
             Catalog.validate(catalog)
  end

  test "rejects duplicate transitions and duplicate normalized criteria" do
    duplicate_transition = sample_catalog([fixture("first"), fixture("second")])

    assert {:error, %{"field" => "catalog.fixtures", "reason" => "duplicate_transition"}} =
             Catalog.validate(duplicate_transition)

    duplicate_criterion =
      fixture("first")
      |> put_in(["input", "acceptance_criteria"], ["same", " same "])

    assert {:error,
            %{
              "field" => "catalog.fixtures[0].input.acceptance_criteria",
              "reason" => "duplicate_criterion"
            }} = Catalog.validate(sample_catalog([duplicate_criterion]))
  end

  test "rejects invalid OIDs" do
    bad = fixture("a-first") |> Map.put("base_commit_oid", "not-an-oid")

    assert {:error,
            %{
              "field" => "catalog.fixtures[0].base_commit_oid",
              "reason" => "invalid_oid"
            }} = Catalog.validate(sample_catalog([bad]))
  end

  test "rejects mixed Git object formats within a fixture" do
    mixed = fixture("a-first") |> Map.put("target_tree_oid", String.duplicate("a", 64))

    assert {:error,
            %{
              "field" => "catalog.fixtures[0]",
              "reason" => "mixed_object_formats"
            }} = Catalog.validate(sample_catalog([mixed]))
  end

  test "rejects malformed list tails and invalid UTF-8 without raising" do
    improper_fixtures =
      sample_catalog([fixture("a-first") | :not_a_json_list])

    assert {:error, %{"field" => "catalog.fixtures", "reason" => "expected_list"}} =
             Catalog.validate(improper_fixtures)

    invalid_utf8 = fixture("a-first") |> Map.put("base_commit_oid", <<255, 0>>)

    assert {:error,
            %{
              "field" => "catalog.fixtures[0].base_commit_oid",
              "reason" => "invalid_oid"
            }} = Catalog.validate(sample_catalog([invalid_utf8]))
  end

  test "rejects identical base and target commits or trees" do
    same_commit =
      fixture("a-first")
      |> Map.put("target_commit_oid", @base_commit)
      |> Map.put("target_tree_oid", @target_tree)

    assert {:error,
            %{
              "field" => "catalog.fixtures[0].target_commit_oid",
              "reason" => "base_and_target_commit_identical"
            }} = Catalog.validate(sample_catalog([same_commit]))

    same_tree =
      fixture("a-first")
      |> Map.put("target_commit_oid", @target_commit)
      |> Map.put("target_tree_oid", @base_tree)

    assert {:error,
            %{
              "field" => "catalog.fixtures[0].target_tree_oid",
              "reason" => "base_and_target_tree_identical"
            }} = Catalog.validate(sample_catalog([same_tree]))
  end

  test "rejects oversized objective text and too many fixtures" do
    huge = fixture("a-first") |> put_in(["input", "objective"], String.duplicate("x", 32_001))

    assert {:error,
            %{
              "field" => "catalog.fixtures[0].input.objective",
              "reason" => "invalid_text"
            }} = Catalog.validate(sample_catalog([huge]))

    many =
      Enum.map(1..21, fn index ->
        fixture("f-#{index}")
      end)

    assert {:error, %{"field" => "catalog.fixtures", "reason" => "too_many_items"}} =
             Catalog.validate(sample_catalog(many))
  end

  test "rejects unsupported schema and empty fixtures" do
    assert {:error, %{"field" => "catalog.schema", "reason" => "unsupported_schema"}} =
             Catalog.validate(Map.put(sample_catalog([fixture("a-first")]), "schema", "v0"))

    assert {:error, %{"field" => "catalog.fixtures", "reason" => "empty_list"}} =
             Catalog.validate(sample_catalog([]))
  end

  test "rejects unknown fixture fields and non-object catalogs" do
    bad = Map.put(fixture("a-first"), "command", "rm -rf /")

    assert {:error, %{"field" => "catalog.fixtures[0]", "reason" => "unknown_field"}} =
             Catalog.validate(sample_catalog([bad]))

    assert {:error, %{"field" => "catalog", "reason" => "expected_object"}} =
             Catalog.validate([])
  end

  test "tracked catalog-v1.json validates and digests" do
    path =
      Path.expand("../../../../../benchmarks/coding/catalog-v1.json", __DIR__)

    assert File.exists?(path)
    assert {:ok, raw} = File.read(path)
    assert {:ok, decoded} = Jason.decode(raw)
    assert {:ok, normalized} = Catalog.validate(decoded)
    assert length(normalized["fixtures"]) == 3

    assert Catalog.digest(normalized) ==
             "85e57b92735a3d6e509cb2a05c1e81f76f1ff1d4b3043be2ab3515a6345992f0"
  end

  defp sample_catalog(fixtures) do
    %{
      "schema" => Catalog.schema(),
      "seed" => 7,
      "source_repository_label" => "arbor",
      "fixtures" => fixtures
    }
  end

  defp fixture(id) do
    %{
      "fixture_id" => id,
      "base_commit_oid" => @base_commit,
      "base_tree_oid" => @base_tree,
      "target_commit_oid" => @target_commit,
      "target_tree_oid" => @target_tree,
      "input" => %{
        "objective" => "Do the work.",
        "acceptance_criteria" => ["criterion-one"]
      },
      "verifier_id" => "exact_target_tree"
    }
  end

  defp alternate_fixture(id) do
    fixture(id)
    |> Map.put("base_commit_oid", String.duplicate("1", 40))
    |> Map.put("base_tree_oid", String.duplicate("2", 40))
    |> Map.put("target_commit_oid", String.duplicate("3", 40))
    |> Map.put("target_tree_oid", String.duplicate("4", 40))
  end
end
