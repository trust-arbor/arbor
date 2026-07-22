defmodule Arbor.Contracts.Coding.WorkPacketTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.WorkPacket

  @moduletag :fast

  @valid %{
    "success_criteria" => ["focused tests pass", "the contract is JSON-clean"],
    "non_goals" => ["Plan v2"],
    "constraints" => ["touch only owned files"],
    "architecture_refs" => ["apps/arbor_contracts/lib/arbor/contracts/coding/plan.ex"],
    "required_evidence" => ["focused test output"],
    "checkpoint_policy" => "direct"
  }

  test "constructs the versioned canonical packet and exposes schema metadata" do
    assert WorkPacket.schema_version() == 1
    assert WorkPacket.checkpoint_policies() == ["direct", "design_required"]
    assert WorkPacket.enums() == %{"checkpoint_policy" => ["direct", "design_required"]}
    assert WorkPacket.schema().version == 1
    assert WorkPacket.max_packet_bytes() == 256_000

    assert {:ok, packet} = WorkPacket.new(@valid)
    assert packet.version == 1
    assert packet.checkpoint_policy == "direct"
    assert packet.non_goals == ["Plan v2"]
    assert packet.constraints == ["touch only owned files"]

    assert packet.architecture_refs == [
             "apps/arbor_contracts/lib/arbor/contracts/coding/plan.ex"
           ]

    assert WorkPacket.to_map(packet) == Map.put(@valid, "version", 1)
    assert {:ok, normalized} = WorkPacket.normalize(success_criteria: ["focused tests pass"])
    assert normalized["checkpoint_policy"] == "direct"
    assert normalized["non_goals"] == []
  end

  test "normalizes atom and string aliases to the same digest" do
    atom_attrs = [
      version: 1,
      success_criteria: ["one", "two"],
      non_goals: ["not allowed"],
      checkpoint_policy: :design_required
    ]

    string_attrs = %{
      "version" => 1,
      "success_criteria" => ["one", "two"],
      "non_goals" => ["not allowed"],
      "checkpoint_policy" => "design_required"
    }

    assert {:ok, atom_packet} = WorkPacket.new(atom_attrs)
    assert {:ok, string_packet} = WorkPacket.new(string_attrs)

    assert {:ok, atom_bytes} = WorkPacket.canonical_bytes(atom_packet)
    assert {:ok, string_bytes} = WorkPacket.canonical_bytes(string_packet)
    assert atom_bytes == string_bytes

    assert {:ok, atom_digest} = WorkPacket.sha256(atom_attrs)
    assert {:ok, string_digest} = WorkPacket.sha256(string_attrs)
    assert atom_digest == string_digest
    assert atom_digest == Base.encode16(:crypto.hash(:sha256, atom_bytes), case: :lower)
  end

  test "canonical bytes do not depend on input object order" do
    first = [
      success_criteria: ["one"],
      constraints: ["two"],
      architecture_refs: ["lib/example.ex"],
      checkpoint_policy: :design_required
    ]

    second = %{
      "checkpoint_policy" => "design_required",
      "architecture_refs" => ["lib/example.ex"],
      "constraints" => ["two"],
      "success_criteria" => ["one"]
    }

    assert {:ok, first_bytes} = WorkPacket.canonical_bytes(first)
    assert {:ok, second_bytes} = WorkPacket.canonical_bytes(second)
    assert first_bytes == second_bytes
  end

  test "requires a non-empty success criteria list and applies bounds" do
    assert {:error, {:missing_field, "success_criteria"}} = WorkPacket.new(%{})

    assert {:error, {:invalid_field, "success_criteria", :must_be_non_empty}} =
             WorkPacket.new(Map.put(@valid, "success_criteria", []))

    too_many = List.duplicate("criterion", WorkPacket.max_list_items() + 1)

    assert {:error, {:invalid_field, "success_criteria", :list_too_large}} =
             WorkPacket.new(Map.put(@valid, "success_criteria", too_many))

    too_long = String.duplicate("x", WorkPacket.max_text_bytes() + 1)

    assert {:error, {:invalid_field, "success_criteria[0]", :text_too_large}} =
             WorkPacket.new(Map.put(@valid, "success_criteria", [too_long]))

    assert {:error, {:invalid_field, "constraints", :list_too_large}} =
             WorkPacket.new(Map.put(@valid, "constraints", too_many))
  end

  test "rejects closed-object violations, aliases, authority, and hostile terms" do
    assert {:error, {:unknown_fields, ["capabilities"]}} =
             WorkPacket.new(Map.put(@valid, "capabilities", ["all"]))

    assert {:error, {:unknown_fields, ["secret"]}} =
             WorkPacket.new(Map.put(@valid, "secret", "value"))

    assert {:error, {:unknown_fields, ["callback"]}} =
             WorkPacket.new(Map.put(@valid, "callback", &String.trim/1))

    assert {:error, {:duplicate_fields, ["success_criteria"]}} =
             WorkPacket.new([{"success_criteria", ["two"]}, success_criteria: ["one"]])

    assert {:error, {:invalid_object, :struct_not_allowed}} = WorkPacket.new(DateTime.utc_now())

    hostile_values = [
      self(),
      fn -> :not_json end,
      {:tuple, :not_json},
      %{nested: :not_json},
      ["valid" | :improper]
    ]

    for value <- hostile_values do
      refute WorkPacket.valid?(Map.put(@valid, "success_criteria", value))
    end
  end

  test "rejects unknown, oversized, improper, and non-object inputs without raising" do
    oversized_object =
      Enum.reduce(1..(WorkPacket.max_fields() + 1), @valid, fn index, attrs ->
        Map.put(attrs, "unknown_#{index}", "value")
      end)

    assert {:error, {:invalid_object, :object_too_large}} = WorkPacket.new(oversized_object)

    assert {:error, {:invalid_object, :object_too_large}} =
             WorkPacket.new([success_criteria: ["one"]] ++ List.duplicate({:version, 1}, 7))

    assert {:error, {:invalid_object, :improper_list}} =
             WorkPacket.new([{:success_criteria, ["one"]} | :improper])

    for input <- [nil, "packet", 42, {:packet, []}, ["not", "an", "object"]] do
      assert {:error, _reason} = WorkPacket.new(input)
      refute WorkPacket.valid?(input)
    end
  end

  test "accepts only the closed checkpoint policy enum" do
    assert {:ok, packet} = WorkPacket.new(Map.put(@valid, "checkpoint_policy", :design_required))
    assert packet.checkpoint_policy == "design_required"

    for policy <- ["ask", :automatic, nil, 1, %{mode: "direct"}] do
      refute WorkPacket.valid?(Map.put(@valid, "checkpoint_policy", policy))
    end
  end

  test "accepts canonical repository-relative POSIX architecture references only" do
    assert {:ok, _} =
             WorkPacket.new(Map.put(@valid, "architecture_refs", [".arbor/roadmap/item.md"]))

    invalid_paths = [
      "",
      ".",
      "..",
      "/etc/passwd",
      "./lib/plan.ex",
      "lib/../secret.ex",
      "lib/./plan.ex",
      "lib//plan.ex",
      "lib/plan.ex/",
      "C:\\Windows\\system.ini",
      "C:/Windows/system.ini",
      "\\\\server\\share\\file",
      "\\rooted\\file",
      "lib\\plan.ex",
      "lib/plan.ex" <> <<0>> <> ".bak",
      "lib/plan.ex\n"
    ]

    for path <- invalid_paths do
      assert {:error, {:invalid_field, "architecture_refs[0]", _reason}} =
               WorkPacket.new(Map.put(@valid, "architecture_refs", [path]))
    end

    too_long = String.duplicate("a", WorkPacket.max_architecture_ref_bytes() + 1)

    assert {:error, {:invalid_field, "architecture_refs[0]", :text_too_large}} =
             WorkPacket.new(Map.put(@valid, "architecture_refs", [too_long]))
  end

  test "canonical maps contain only JSON-clean string-keyed data" do
    assert {:ok, packet} = WorkPacket.new(@valid)
    map = WorkPacket.to_map(packet)

    assert Map.keys(map) |> Enum.all?(&is_binary/1)
    assert {:ok, json} = Jason.encode(map)
    assert Jason.decode!(json) == map
    assert WorkPacket.valid?(packet)

    assert WorkPacket.to_map(:not_a_packet) ==
             {:error, {:invalid_work_packet, :struct_required}}

    for value <- [self(), &String.trim/1, {:bad, :term}, %{atom: :value}] do
      refute WorkPacket.valid?(Map.put(@valid, "required_evidence", [value]))

      assert {:error, _reason} =
               WorkPacket.canonical_bytes(Map.put(@valid, "required_evidence", [value]))

      assert {:error, _reason} = WorkPacket.sha256(Map.put(@valid, "required_evidence", [value]))
    end
  end
end
