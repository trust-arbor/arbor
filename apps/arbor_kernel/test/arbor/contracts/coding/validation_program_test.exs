defmodule Arbor.Contracts.Coding.ValidationProgramTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.ValidationProgram

  @moduletag :fast

  @path_a "apps/foo/test/alpha_test.exs"
  @path_b "apps/foo/test/beta_test.exs"
  @snapshot "sha256:" <> String.duplicate("a", 64)
  @inventory [@path_a, @path_b]

  @valid %{
    "schema_version" => 1,
    "profile" => "default",
    "stages" => [
      %{"kind" => "mix_compile", "profile" => "test"},
      %{"kind" => "mix_test", "paths" => [@path_b, @path_a]}
    ],
    "snapshot_digest" => @snapshot,
    "budget" => %{
      "compile_share_ms" => 1_000,
      "evidence_share_ms" => 2_000,
      "total_ms" => 4_000
    },
    "deadline_unix_ms" => 1_777_000_000_000,
    "containment_profile" => "default",
    "executor_version" => "1",
    "inventory" => @inventory
  }

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(@valid, overrides)
  end

  defp program!(overrides \\ %{}) do
    assert {:ok, program} = ValidationProgram.new(valid_attrs(overrides))
    program
  end

  test "new/1 accepts a valid manifest" do
    assert ValidationProgram.schema_version() == 1
    assert ValidationProgram.stage_kinds() == [:mix_compile, :mix_test]

    program = program!()
    assert program.schema_version == 1
    assert program.profile == "default"
    assert program.snapshot_digest == @snapshot
    assert program.budget.compile_share_ms == 1_000
    assert program.budget.evidence_share_ms == 2_000
    assert program.budget.total_ms == 4_000

    assert program.stages == [
             %{kind: :mix_compile, profile: "test"},
             %{kind: :mix_test, paths: Enum.sort([@path_a, @path_b])}
           ]
  end

  test "new/1 rejects an unknown stage" do
    attrs =
      valid_attrs(%{
        "stages" => [
          %{"kind" => "mix_format", "profile" => "test"}
        ]
      })

    assert {:error, {:invalid_field, "stages", :unknown_stage}} = ValidationProgram.new(attrs)
  end

  test "new/1 rejects empty mix_test paths" do
    attrs =
      valid_attrs(%{
        "stages" => [
          %{"kind" => "mix_compile", "profile" => "test"},
          %{"kind" => "mix_test", "paths" => []}
        ]
      })

    assert {:error, {:invalid_field, "stages", :empty_mix_test_paths}} =
             ValidationProgram.new(attrs)
  end

  test "new/1 rejects a missing snapshot_digest" do
    attrs = Map.delete(@valid, "snapshot_digest")
    assert {:error, {:missing_field, "snapshot_digest"}} = ValidationProgram.new(attrs)
  end

  test "new/1 rejects budget shares over total" do
    attrs =
      valid_attrs(%{
        "budget" => %{
          "compile_share_ms" => 3_000,
          "evidence_share_ms" => 2_000,
          "total_ms" => 4_000
        }
      })

    assert {:error, {:invalid_field, "budget", :shares_exceed_total}} =
             ValidationProgram.new(attrs)
  end

  describe "admit_test_paths/2" do
    test "returns sorted unique regular-file paths" do
      assert {:ok, [@path_a, @path_b]} =
               ValidationProgram.admit_test_paths([@path_b, @path_a], @inventory)
    end

    test "rejects an absolute path" do
      assert {:error, {:invalid_test_path, :absolute}} =
               ValidationProgram.admit_test_paths(["/" <> @path_a], @inventory)
    end

    test "rejects a parent-segment path" do
      assert {:error, {:invalid_test_path, :dot_dot}} =
               ValidationProgram.admit_test_paths(["apps/../#{@path_a}"], @inventory)
    end

    test "rejects a NUL byte" do
      assert {:error, {:invalid_test_path, :nul}} =
               ValidationProgram.admit_test_paths([@path_a <> <<0>>], @inventory)
    end

    test "rejects a leading dash component" do
      assert {:error, {:invalid_test_path, :leading_dash}} =
               ValidationProgram.admit_test_paths(["-evil_test.exs"], ["-evil_test.exs"])
    end

    test "rejects a non-_test.exs suffix" do
      assert {:error, {:invalid_test_path, :not_test_exs}} =
               ValidationProgram.admit_test_paths(["apps/foo/test/helper.exs"], [
                 "apps/foo/test/helper.exs"
               ])
    end

    test "rejects a directory by inventory type, not lexical prefix" do
      inventory = [
        @path_a,
        {@path_b, :directory},
        "apps/foo/test/nested/gamma_test.exs"
      ]

      assert {:error, {:invalid_test_path, :directory}} =
               ValidationProgram.admit_test_paths([@path_b], inventory)

      assert {:ok, [@path_a]} = ValidationProgram.admit_test_paths([@path_a], inventory)

      assert {:ok, ["apps/foo/test/nested/gamma_test.exs"]} =
               ValidationProgram.admit_test_paths(
                 ["apps/foo/test/nested/gamma_test.exs"],
                 inventory
               )
    end

    test "rejects a symlink by inventory type" do
      inventory = [{@path_a, :symlink}, @path_b]

      assert {:error, {:invalid_test_path, :symlink}} =
               ValidationProgram.admit_test_paths([@path_a], inventory)
    end

    test "rejects a path that is not in the inventory" do
      assert {:error, {:invalid_test_path, :not_in_inventory}} =
               ValidationProgram.admit_test_paths(
                 ["apps/foo/test/missing_test.exs"],
                 @inventory
               )
    end

    test "rejects invalid UTF-8" do
      assert {:error, {:invalid_test_path, :invalid_utf8}} =
               ValidationProgram.admit_test_paths([<<0xFF, 0xFE>>], @inventory)
    end

    test "NFC-normalizes equivalent Unicode forms to one inventory path" do
      nfc = "apps/foo/test/caf\u00E9_test.exs"
      nfd = "apps/foo/test/cafe\u0301_test.exs"
      assert String.normalize(nfd, :nfc) == nfc

      assert {:ok, [^nfc]} = ValidationProgram.admit_test_paths([nfd], [nfc])
    end

    test "rejects duplicates after normalization" do
      nfc = "apps/foo/test/caf\u00E9_test.exs"
      nfd = "apps/foo/test/cafe\u0301_test.exs"

      assert {:error, {:invalid_test_path, :duplicate}} =
               ValidationProgram.admit_test_paths([nfc, nfd], [nfc])
    end

    test "orders admitted paths independently of request order" do
      assert {:ok, first} = ValidationProgram.admit_test_paths([@path_b, @path_a], @inventory)
      assert {:ok, second} = ValidationProgram.admit_test_paths([@path_a, @path_b], @inventory)
      assert first == second
      assert first == Enum.sort([@path_a, @path_b])
    end
  end

  test "canonical_encode/digest are deterministic across map key order and change with fields" do
    base = valid_attrs()

    orders = [
      [
        "schema_version",
        "profile",
        "stages",
        "snapshot_digest",
        "budget",
        "deadline_unix_ms",
        "containment_profile",
        "executor_version",
        "inventory"
      ],
      [
        "inventory",
        "executor_version",
        "containment_profile",
        "deadline_unix_ms",
        "budget",
        "snapshot_digest",
        "stages",
        "profile",
        "schema_version"
      ],
      [
        "budget",
        "stages",
        "profile",
        "inventory",
        "snapshot_digest",
        "schema_version",
        "executor_version",
        "containment_profile",
        "deadline_unix_ms"
      ]
    ]

    encodings =
      Enum.map(orders, fn keys ->
        attrs = Map.new(keys, fn key -> {key, Map.fetch!(base, key)} end)
        program = elem(ValidationProgram.new(attrs), 1)
        {ValidationProgram.canonical_encode(program), ValidationProgram.digest(program)}
      end)

    assert encodings |> Enum.uniq() |> length() == 1
    [{bytes, digest}] = Enum.uniq(encodings)
    assert String.starts_with?(bytes, <<"arbor-coding-validation-v1", 0>>)
    assert digest == "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    budget = %{"evidence_share_ms" => 2_000, "total_ms" => 4_000, "compile_share_ms" => 1_000}
    shuffled_budget = program!(%{"budget" => budget})
    assert ValidationProgram.digest(shuffled_budget) == digest

    mutations = [
      %{"stages" => [%{"kind" => "mix_compile", "profile" => "test"}]},
      %{"snapshot_digest" => "sha256:" <> String.duplicate("b", 64)},
      %{"profile" => "security_regression"},
      %{
        "budget" => %{
          "compile_share_ms" => 1_001,
          "evidence_share_ms" => 2_000,
          "total_ms" => 4_000
        }
      },
      %{
        "stages" => [
          %{"kind" => "mix_test", "paths" => [@path_a, @path_b]},
          %{"kind" => "mix_compile", "profile" => "test"}
        ]
      }
    ]

    Enum.each(mutations, fn override ->
      mutated = program!(override)
      assert ValidationProgram.digest(mutated) != digest
      assert ValidationProgram.canonical_encode(mutated) != bytes
    end)
  end

  test "resource_uri is a path-segment form and parse_resource_uri rejects fragments" do
    program = program!()
    uri = ValidationProgram.resource_uri(program)
    digest = ValidationProgram.digest(program)
    hex = String.replace_prefix(digest, "sha256:", "")

    assert uri == "arbor://action/coding/validate/v1/" <> hex
    refute String.contains?(uri, "#")
    assert {:ok, ^digest} = ValidationProgram.parse_resource_uri(uri)

    assert {:error, {:invalid_resource_uri, :fragment}} =
             ValidationProgram.parse_resource_uri("arbor://action/coding/validate/v1#" <> hex)

    assert {:error, {:invalid_resource_uri, :fragment}} =
             ValidationProgram.parse_resource_uri(uri <> "#extra")

    assert {:error, {:invalid_resource_uri, :malformed}} =
             ValidationProgram.parse_resource_uri("arbor://action/coding/validate/v1/")

    assert {:error, {:invalid_resource_uri, :malformed}} =
             ValidationProgram.parse_resource_uri("arbor://action/coding/validate/v2/" <> hex)

    assert {:error, {:invalid_resource_uri, :malformed}} =
             ValidationProgram.parse_resource_uri(uri <> "/extra")
  end

  test "render/1 includes every path and the digest fingerprint" do
    program = program!()
    rendered = ValidationProgram.render(program)
    digest = ValidationProgram.digest(program)
    hex = String.replace_prefix(digest, "sha256:", "")

    assert rendered =~ "profile: default"
    assert rendered =~ "mix_compile(profile=test)"
    assert rendered =~ "mix_test(paths=2)"
    assert rendered =~ @path_a
    assert rendered =~ @path_b
    assert rendered =~ "path_count: 2"
    assert rendered =~ "compile_share_ms=1000"
    assert rendered =~ "evidence_share_ms=2000"
    assert rendered =~ "total_ms=4000"
    assert rendered =~ "snapshot: #{@snapshot}"
    assert rendered =~ digest
    assert rendered =~ hex
  end
end
