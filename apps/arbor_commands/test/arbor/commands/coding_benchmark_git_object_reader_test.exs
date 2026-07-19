defmodule Arbor.Commands.CodingBenchmark.GitObjectReaderTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.CodingBenchmark.Git

  @oid_a String.duplicate("a", 40)
  @oid_b String.duplicate("b", 40)
  @oid_c String.duplicate("c", 40)
  @oid_sha256 String.duplicate("d", 64)

  describe "normalize_object_requests/1" do
    test "accepts closed types and 40/64-hex oids, dedupes exact duplicates" do
      assert {:ok, [%{oid: @oid_a, type: "blob"}, %{oid: @oid_sha256, type: "tree"}]} =
               Git.normalize_object_requests([
                 %{oid: @oid_a, type: "blob"},
                 %{oid: @oid_a, type: "blob"},
                 %{oid: @oid_sha256, type: "tree"}
               ])
    end

    test "rejects invalid oids, types, and type conflicts on duplicate oids" do
      assert {:error, "git_invalid_object_oid"} =
               Git.normalize_object_requests([%{oid: "not-an-oid", type: "blob"}])

      assert {:error, "git_invalid_object_type"} =
               Git.normalize_object_requests([%{oid: @oid_a, type: "tag"}])

      assert {:error, "git_object_type_conflict"} =
               Git.normalize_object_requests([
                 %{oid: @oid_a, type: "blob"},
                 %{oid: @oid_a, type: "tree"}
               ])
    end
  end

  describe "parse_batch_check_output/2" do
    test "parses ordered check lines and rejects missing/malformed/mismatched rows" do
      requests = [%{oid: @oid_a, type: "blob"}, %{oid: @oid_b, type: "tree"}]
      good = "#{@oid_a} blob 12\n#{@oid_b} tree 34\n"

      assert {:ok,
              [%{oid: @oid_a, type: "blob", size: 12}, %{oid: @oid_b, type: "tree", size: 34}]} =
               Git.parse_batch_check_output(good, requests)

      assert {:error, "git_object_missing"} =
               Git.parse_batch_check_output("#{@oid_a} missing\n#{@oid_b} tree 1\n", requests)

      assert {:error, "git_batch_check_type_mismatch"} =
               Git.parse_batch_check_output("#{@oid_a} tree 12\n#{@oid_b} tree 34\n", requests)

      assert {:error, "git_batch_check_oid_mismatch"} =
               Git.parse_batch_check_output("#{@oid_c} blob 12\n#{@oid_b} tree 34\n", requests)

      assert {:error, "git_batch_check_count_mismatch"} =
               Git.parse_batch_check_output("#{@oid_a} blob 12\n", requests)

      assert {:error, "git_batch_check_malformed"} =
               Git.parse_batch_check_output("not a header\n#{@oid_b} tree 34\n", requests)
    end

    test "rejects missing final newline and empty internal lines" do
      requests = [%{oid: @oid_a, type: "blob"}]

      assert {:error, "git_batch_check_missing_final_newline"} =
               Git.parse_batch_check_output("#{@oid_a} blob 12", requests)

      assert {:error, "git_batch_check_missing_final_newline"} =
               Git.parse_batch_check_output(
                 "#{@oid_a} blob 12\n#{@oid_b} tree 1",
                 [%{oid: @oid_a, type: "blob"}, %{oid: @oid_b, type: "tree"}]
               )

      assert {:error, "git_batch_check_malformed"} =
               Git.parse_batch_check_output("#{@oid_a} blob 12\n\n", requests)

      assert {:error, "git_batch_check_count_mismatch"} =
               Git.parse_batch_check_output("", requests)
    end
  end

  describe "bounded_diagnostic_output/1" do
    test "is total for invalid UTF-8 and binary batch bytes" do
      invalid = <<0xFF, 0xFE, "blob", 0, 1, 2, "\n">>
      assert is_binary(Git.bounded_diagnostic_output(invalid))
      assert byte_size(Git.bounded_diagnostic_output(invalid)) <= 500
      refute String.contains?(Git.bounded_diagnostic_output(invalid), <<0>>)

      huge = :binary.copy(<<0x80>>, 2_000)
      assert byte_size(Git.bounded_diagnostic_output(huge)) <= 500

      assert Git.bounded_diagnostic_output("  printable text  ") == "printable text"
      assert is_binary(Git.bounded_diagnostic_output({:error, :not_a_binary}))
    end
  end

  describe "read_objects/4 request cardinality" do
    test "rejects empty and oversized request lists before shell execution" do
      assert {:error, "git_empty_object_request"} =
               Git.read_objects("/tmp", [], 1_000)

      assert {:error, "git_empty_object_request"} =
               Git.normalize_object_requests([])

      max = Git.max_object_requests()
      assert max == 10_002

      oversized =
        for index <- 1..(max + 1) do
          oid =
            index
            |> Integer.to_string(16)
            |> String.downcase()
            |> String.pad_leading(40, "0")

          %{oid: oid, type: "blob"}
        end

      assert length(oversized) == max + 1

      assert {:error, "git_object_request_limit"} =
               Git.normalize_object_requests(oversized)

      assert {:error, "git_object_request_limit"} =
               Git.read_objects("/tmp", oversized, 1_000)

      # Zero-byte objects still consume request cardinality.
      zero_byte_like =
        for index <- 1..(max + 1) do
          oid =
            index
            |> Integer.to_string(16)
            |> String.downcase()
            |> String.pad_leading(40, "0")

          %{oid: oid, type: "blob"}
        end

      assert {:error, "git_object_request_limit"} =
               Git.normalize_object_requests(zero_byte_like)
    end

    test "accepts the fixture ceiling plus commit and root-tree requests" do
      max = Git.max_object_requests()

      at_limit =
        for index <- 1..max do
          oid =
            index
            |> Integer.to_string(16)
            |> String.downcase()
            |> String.pad_leading(40, "0")

          type =
            case rem(index, 3) do
              0 -> "commit"
              1 -> "tree"
              _other -> "blob"
            end

          %{oid: oid, type: type}
        end

      assert {:ok, normalized} = Git.normalize_object_requests(at_limit)
      assert length(normalized) == max
    end
  end

  describe "parse_batch_objects_output/2" do
    test "parses binary content including embedded newlines and rejects corrupt frames" do
      content_a = "line1\nline2\n\x00binary"
      content_b = "second"
      size_a = byte_size(content_a)
      size_b = byte_size(content_b)

      payload =
        IO.iodata_to_binary([
          @oid_a,
          " blob ",
          Integer.to_string(size_a),
          "\n",
          content_a,
          "\n",
          @oid_b,
          " blob ",
          Integer.to_string(size_b),
          "\n",
          content_b,
          "\n"
        ])

      specs = [
        %{oid: @oid_a, type: "blob", size: size_a},
        %{oid: @oid_b, type: "blob", size: size_b}
      ]

      assert {:ok, objects} = Git.parse_batch_objects_output(payload, specs)
      assert objects[@oid_a].content == content_a
      assert objects[@oid_b].content == content_b
      assert objects[@oid_a].size == size_a

      assert {:error, "git_batch_type_mismatch"} =
               Git.parse_batch_objects_output(payload, [
                 %{oid: @oid_a, type: "tree", size: size_a},
                 %{oid: @oid_b, type: "blob", size: size_b}
               ])

      assert {:error, "git_batch_size_or_order_mismatch"} =
               Git.parse_batch_objects_output(payload, [
                 %{oid: @oid_a, type: "blob", size: size_a + 1},
                 %{oid: @oid_b, type: "blob", size: size_b}
               ])

      assert {:error, "git_batch_trailing_bytes"} =
               Git.parse_batch_objects_output(payload <> "extra", specs)

      truncated = binary_part(payload, 0, byte_size(payload) - 3)

      assert {:error, reason} = Git.parse_batch_objects_output(truncated, specs)
      assert reason in ["git_batch_payload_truncated", "git_batch_header_malformed"]

      missing =
        IO.iodata_to_binary([
          @oid_a,
          " missing\n"
        ])

      assert {:error, "git_object_missing"} =
               Git.parse_batch_objects_output(missing, [
                 %{oid: @oid_a, type: "blob", size: 1}
               ])
    end

    test "copies retained content so batch buffers are not accidentally shared" do
      content = "owned-bytes"
      size = byte_size(content)

      payload =
        IO.iodata_to_binary([@oid_a, " blob ", Integer.to_string(size), "\n", content, "\n"])

      assert {:ok, objects} =
               Git.parse_batch_objects_output(payload, [
                 %{oid: @oid_a, type: "blob", size: size}
               ])

      retained = objects[@oid_a].content
      assert retained == content
      assert :binary.referenced_byte_size(retained) == byte_size(retained)
    end
  end

  describe "partition_objects_for_batch/2" do
    test "groups objects under the output ceiling and singles oversized members" do
      small = %{oid: @oid_a, type: "blob", size: 10}
      medium = %{oid: @oid_b, type: "blob", size: 20}
      # Force single-object path: wire size exceeds a tiny ceiling.
      large = %{oid: @oid_c, type: "blob", size: 50}

      assert wire = Git.batch_object_wire_bytes(large)
      ceiling = wire - 1

      assert {:ok, batches} =
               Git.partition_objects_for_batch([small, medium, large], ceiling)

      assert {:single, ^large} = List.last(batches)
      assert Enum.any?(batches, &match?({:batch, _specs}, &1))

      assert {:ok, [{:batch, group}]} =
               Git.partition_objects_for_batch([small, medium], 10_000)

      assert Enum.map(group, & &1.oid) == [@oid_a, @oid_b]
    end

    test "splits when cumulative batch budget would overflow" do
      first = %{oid: @oid_a, type: "blob", size: 30}
      second = %{oid: @oid_b, type: "blob", size: 30}
      first_wire = Git.batch_object_wire_bytes(first)
      second_wire = Git.batch_object_wire_bytes(second)
      # Enough for either alone, not both.
      ceiling = max(first_wire, second_wire)

      assert {:ok, [{:batch, [^first]}, {:batch, [^second]}]} =
               Git.partition_objects_for_batch([first, second], ceiling)
    end
  end
end
