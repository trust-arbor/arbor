defmodule Arbor.Contracts.Coding.ValidationProgramTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.ValidationProgram

  @moduletag :fast

  @path_a "apps/foo/test/alpha_test.exs"
  @path_b "apps/foo/test/beta_test.exs"
  @snapshot "sha256:" <> String.duplicate("a", 64)
  @inventory [@path_a, @path_b]

  # Independent golden vector for the admitted @valid fixture (paths sorted
  # alpha then beta). Computed offline from the published length-delimited
  # layout, not from ValidationProgram.canonical_encode/1:
  #
  #   "arbor-coding-validation-v1\0"
  #   || be32(schema_version=1)
  #   || be32(7) || "default"
  #   || be32(2)
  #   || be32(11) || "mix_compile" || be32(4) || "test"
  #   || be32(8) || "mix_test" || be32(2)
  #      || be32(28) || "apps/foo/test/alpha_test.exs"
  #      || be32(27) || "apps/foo/test/beta_test.exs"
  #   || be32(71) || "sha256:" || 64 * "a"
  #   || be64(1000) || be64(2000) || be64(4000)
  #   || be64(1_777_000_000_000)
  #   || be32(7) || "default"
  #   || be32(1) || "1"
  @golden_canonical_hex "6172626f722d636f64696e672d76616c69646174696f6e2d763100000000010000000764656661756c74000000020000000b6d69785f636f6d70696c650000000474657374000000086d69785f74657374000000020000001c617070732f666f6f2f746573742f616c7068615f746573742e6578730000001b617070732f666f6f2f746573742f626574615f746573742e657873000000477368613235363a6161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616100000000000003e800000000000007d00000000000000fa00000019dbd742a000000000764656661756c740000000131"
  @golden_digest "sha256:f731999e50383f7ef91b3a8c2c000926fa8ab5c9dd8de6947a25b29a54c5d1b2"
  @golden_uri "arbor://action/coding/validate/v1/f731999e50383f7ef91b3a8c2c000926fa8ab5c9dd8de6947a25b29a54c5d1b2"

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

  test "new/1 rejects malformed snapshot_digest values" do
    Enum.each(
      [
        "not-a-digest",
        "sha256:" <> String.duplicate("a", 63),
        "sha256:" <> String.duplicate("a", 65),
        "sha256:" <> String.duplicate("A", 64),
        "SHA256:" <> String.duplicate("a", 64),
        "md5:" <> String.duplicate("a", 32),
        "sha256:" <> String.duplicate("g", 64)
      ],
      fn digest ->
        assert {:error, {:invalid_field, "snapshot_digest", :not_a_digest}} =
                 ValidationProgram.new(valid_attrs(%{"snapshot_digest" => digest}))
      end
    )
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

  test "new/1 rejects control characters in rendered text fields" do
    Enum.each(["default\n", "default\r", "default\t", "default" <> <<0x1B>>], fn profile ->
      assert {:error, {:invalid_field, "profile", :control_character}} =
               ValidationProgram.new(valid_attrs(%{"profile" => profile}))
    end)
  end

  test "new/1 indexes inventory once across multiple mix_test stages" do
    attrs =
      valid_attrs(%{
        "stages" => [
          %{"kind" => "mix_compile", "profile" => "test"},
          %{"kind" => "mix_test", "paths" => [@path_a]},
          %{"kind" => "mix_test", "paths" => [@path_b]}
        ]
      })

    assert {:ok, program} = ValidationProgram.new(attrs)

    assert program.stages == [
             %{kind: :mix_compile, profile: "test"},
             %{kind: :mix_test, paths: [@path_a]},
             %{kind: :mix_test, paths: [@path_b]}
           ]
  end

  describe "admit_test_paths/2" do
    test "returns sorted unique regular-file paths" do
      assert {:ok, [@path_a, @path_b]} =
               ValidationProgram.admit_test_paths([@path_b, @path_a], @inventory)
    end

    test "regression: an inventory larger than 4,096 entries is admitted (a real monorepo exceeds that)" do
      # Council cycle 2 (2026-08-29): the 4,096 cap rejected every real tree —
      # this umbrella alone tracks >4,100 files.
      big = for i <- 1..5_000, do: "apps/x/lib/file_#{i}.ex"
      inventory = [@path_a | big]

      assert {:ok, [@path_a]} = ValidationProgram.admit_test_paths([@path_a], inventory)
    end

    test "regression: an oversized path is refused by length before any codepoint scan" do
      long = String.duplicate("a", 5_000) <> "_test.exs"

      assert {:error, {:invalid_test_path, :path_too_long}} =
               ValidationProgram.admit_test_paths([long], @inventory)
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

    test "rejects newline, CR, tab, and ANSI escape in requested paths" do
      Enum.each(
        [
          @path_a <> "\n",
          @path_a <> "\r",
          @path_a <> "\t",
          @path_a <> <<0x1B>>
        ],
        fn path ->
          assert {:error, {:invalid_test_path, :control_character}} =
                   ValidationProgram.admit_test_paths([path], [path])
        end
      )
    end

    test "tags inventory-entry failures separately from requested-path failures" do
      assert {:error, {:invalid_inventory, :empty_path}} =
               ValidationProgram.admit_test_paths([@path_a], [""])

      assert {:error, {:invalid_inventory, :dot_component}} =
               ValidationProgram.admit_test_paths([@path_a], ["./#{@path_a}"])
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

  test "pins an independently computed golden canonical vector" do
    program = program!()
    bytes = ValidationProgram.canonical_encode(program)
    digest = ValidationProgram.digest(program)
    uri = ValidationProgram.resource_uri(program)

    assert bytes == Base.decode16!(@golden_canonical_hex, case: :lower)
    assert digest == @golden_digest
    assert uri == @golden_uri
    assert digest == "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert {:ok, ^digest} = ValidationProgram.parse_resource_uri(uri)
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
    assert bytes == Base.decode16!(@golden_canonical_hex, case: :lower)
    assert digest == @golden_digest

    budget = %{"evidence_share_ms" => 2_000, "total_ms" => 4_000, "compile_share_ms" => 1_000}
    shuffled_budget = program!(%{"budget" => budget})
    assert ValidationProgram.digest(shuffled_budget) == digest

    mutations = [
      %{"profile" => "security_regression"},
      %{"snapshot_digest" => "sha256:" <> String.duplicate("b", 64)},
      %{
        "budget" => %{
          "compile_share_ms" => 1_001,
          "evidence_share_ms" => 2_000,
          "total_ms" => 4_000
        }
      },
      %{"deadline_unix_ms" => 1_777_000_000_001},
      %{"containment_profile" => "apple"},
      %{"executor_version" => "2"},
      %{
        "stages" => [
          %{"kind" => "mix_compile", "profile" => "dev"},
          %{"kind" => "mix_test", "paths" => [@path_a, @path_b]}
        ]
      },
      %{
        "stages" => [
          %{"kind" => "mix_test", "paths" => [@path_a, @path_b]},
          %{"kind" => "mix_compile", "profile" => "test"}
        ]
      },
      %{
        "stages" => [
          %{"kind" => "mix_compile", "profile" => "test"},
          %{"kind" => "mix_test", "paths" => [@path_a]}
        ]
      }
    ]

    Enum.each(mutations, fn override ->
      mutated = program!(override)
      assert ValidationProgram.digest(mutated) != digest
      assert ValidationProgram.canonical_encode(mutated) != bytes
    end)
  end

  test "resource_uri is a path-segment form and parse_resource_uri rejects aliases" do
    program = program!()
    uri = ValidationProgram.resource_uri(program)
    digest = ValidationProgram.digest(program)
    hex = String.replace_prefix(digest, "sha256:", "")

    assert uri == @golden_uri
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

    assert {:error, {:invalid_resource_uri, :malformed}} =
             ValidationProgram.parse_resource_uri(uri <> "/")

    assert {:error, {:invalid_resource_uri, :malformed}} =
             ValidationProgram.parse_resource_uri(<<0xFF, 0xFE>> <> uri)
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
    refute rendered =~ "\r"
    refute rendered =~ <<0x1B>>
  end
end
