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

    test "caps content batches at 64 objects even when wire budget allows more" do
      max = Git.max_cat_file_batch_objects()
      assert max == 64

      # Zero-byte objects so only the cardinality ceiling can force a split.
      at_limit = zero_byte_specs(max)
      over_limit = zero_byte_specs(max + 1)

      assert {:ok, [{:batch, group}]} =
               Git.partition_objects_for_batch(at_limit, 16_777_216)

      assert length(group) == max
      assert Enum.map(group, & &1.oid) == Enum.map(at_limit, & &1.oid)

      assert {:ok, [{:batch, first}, {:batch, second}]} =
               Git.partition_objects_for_batch(over_limit, 16_777_216)

      assert length(first) == max
      assert length(second) == 1
      assert Enum.map(first ++ second, & &1.oid) == Enum.map(over_limit, & &1.oid)
    end
  end

  describe "partition_requests_for_check/2" do
    test "caps batch-check requests at 64 even when output budget allows more" do
      max = Git.max_cat_file_batch_objects()
      assert max == 64

      # Generous ceiling so byte-derived capacity exceeds the cardinality bound.
      shell_ceiling = 16_777_216
      at_limit = zero_byte_requests(max)
      over_limit = zero_byte_requests(max + 1)

      assert {:ok, [group]} = Git.partition_requests_for_check(at_limit, shell_ceiling)
      assert length(group) == max
      assert Enum.map(group, & &1.oid) == Enum.map(at_limit, & &1.oid)

      assert {:ok, [first, second]} =
               Git.partition_requests_for_check(over_limit, shell_ceiling)

      assert length(first) == max
      assert length(second) == 1
      assert Enum.map(first ++ second, & &1.oid) == Enum.map(over_limit, & &1.oid)
    end

    test "still respects byte-derived line capacity when it is tighter than 64" do
      # One line overhead is 96 bytes; a 200-byte ceiling admits only 2 lines.
      requests = zero_byte_requests(5)

      assert {:ok, batches} = Git.partition_requests_for_check(requests, 200)
      assert length(batches) == 3
      assert Enum.map(batches, &length/1) == [2, 2, 1]
      assert List.flatten(batches) == requests
    end
  end

  defp zero_byte_specs(count) when is_integer(count) and count > 0 do
    for index <- 1..count do
      %{oid: synthetic_oid(index), type: "blob", size: 0}
    end
  end

  defp zero_byte_requests(count) when is_integer(count) and count > 0 do
    for index <- 1..count do
      %{oid: synthetic_oid(index), type: "blob"}
    end
  end

  defp synthetic_oid(index) when is_integer(index) and index > 0 do
    index
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(40, "0")
  end
end
