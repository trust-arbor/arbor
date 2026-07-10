defmodule Arbor.Orchestrator.CodingPlan.ActionCatalogTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.CodingPlan.ActionCatalog

  defmodule AlphaAction do
    def to_tool do
      %{
        name: "alpha_action",
        description: "Alpha action",
        function: fn _params, _context -> {:ok, "ignored"} end,
        module: __MODULE__,
        owner: self(),
        parameters_schema: %{
          "type" => "object",
          "properties" => %{
            "count" => %{"minimum" => 0, "type" => "integer"},
            "label" => %{"type" => "string"}
          },
          "required" => ["label"]
        }
      }
    end
  end

  defmodule ZebraAction do
    def to_tool do
      %{
        "parameters_schema" => %{
          properties: %{
            enabled: %{"type" => "boolean"}
          },
          type: "object"
        },
        "description" => "Zebra action",
        "name" => "zebra_action"
      }
    end
  end

  defmodule AlphaSchemaChangedAction do
    def to_tool do
      %{
        name: "alpha_action",
        description: "Alpha action",
        parameters_schema: %{
          "type" => "object",
          "properties" => %{
            "count" => %{"minimum" => 1, "type" => "integer"},
            "label" => %{"type" => "string"}
          },
          "required" => ["label"]
        }
      }
    end
  end

  defmodule MissingDescriptionAction do
    def to_tool do
      %{name: "missing_description", parameters_schema: %{"type" => "object"}}
    end
  end

  defmodule InvalidSchemaAction do
    def to_tool do
      %{
        name: "invalid_schema",
        description: "Invalid schema",
        parameters_schema: %{"properties" => %{"callback" => fn -> :ok end}}
      }
    end
  end

  defmodule RaisingAction do
    def to_tool, do: raise("cannot inspect action")
  end

  defmodule LongErrorAction do
    def to_tool, do: raise(String.duplicate("oversized error ", 100))
  end

  @registry_entries [
    {"zebra.action", ZebraAction, %{category: :test}},
    {"zebra_action", ZebraAction, %{category: :test, is_jido_alias: true}},
    {"alpha.action", AlphaAction, %{category: :test}},
    {"alpha_action", AlphaAction, %{category: :test, is_jido_alias: true}}
  ]

  describe "snapshot/1" do
    test "registry and facade shaped sources normalize identically" do
      assert {:ok, from_registry} = ActionCatalog.snapshot(entries: @registry_entries)

      assert {:ok, from_facade} =
               ActionCatalog.snapshot(modules: %{test: [AlphaAction, ZebraAction]})

      assert from_registry == from_facade
    end

    test "orders actions deterministically regardless of source ordering" do
      assert {:ok, forward} = ActionCatalog.snapshot(entries: @registry_entries)
      assert {:ok, reverse} = ActionCatalog.snapshot(entries: Enum.reverse(@registry_entries))

      assert forward == reverse
      assert ActionCatalog.names(forward) == ["alpha_action", "zebra_action"]
      assert forward["digest"] =~ ~r/^[0-9a-f]{64}$/
    end

    test "deduplicates registry aliases by action module" do
      assert {:ok, snapshot} = ActionCatalog.snapshot(entries: @registry_entries)

      assert length(snapshot["actions"]) == 2
      assert Enum.count(snapshot["actions"], &(&1["name"] == "alpha_action")) == 1
      assert Enum.count(snapshot["actions"], &(&1["name"] == "zebra_action")) == 1
    end

    test "retains only JSON-clean compilation fields" do
      assert {:ok, snapshot} = ActionCatalog.snapshot(modules: [AlphaAction, ZebraAction])
      assert {:ok, encoded} = Jason.encode(snapshot)
      assert is_binary(encoded)

      assert Enum.all?(snapshot["actions"], fn action ->
               Map.keys(action) |> Enum.sort() ==
                 ["description", "name", "parameters_schema"]
             end)

      assert {:ok, zebra} = ActionCatalog.fetch(snapshot, "zebra_action")

      assert zebra["parameters_schema"] == %{
               "properties" => %{"enabled" => %{"type" => "boolean"}},
               "type" => "object"
             }

      refute contains_runtime_value?(snapshot)
    end

    test "fails explicitly for malformed registry entries" do
      assert {:error, {:invalid_registry_entry, 1}} =
               ActionCatalog.snapshot(entries: [hd(@registry_entries), :malformed])
    end

    test "fails explicitly for malformed and uninspectable action specs" do
      assert {:error, {:invalid_action_spec, _module, {:missing_field, "description"}}} =
               ActionCatalog.snapshot(modules: [MissingDescriptionAction])

      assert {:error, {:invalid_action_spec, _module, {:unsupported_value, _path}}} =
               ActionCatalog.snapshot(modules: [InvalidSchemaAction])

      assert {:error, {:action_uninspectable, _module, message}} =
               ActionCatalog.snapshot(modules: [RaisingAction])

      assert message == "cannot inspect action"
      refute message =~ File.cwd!()

      assert {:error, {:action_uninspectable, _module, long_message}} =
               ActionCatalog.snapshot(modules: [LongErrorAction])

      assert byte_size(long_message) <= 512
      assert String.ends_with?(long_message, "...")
    end

    test "changes the digest when a parameter schema changes" do
      assert {:ok, original} = ActionCatalog.snapshot(modules: [AlphaAction])
      assert {:ok, changed} = ActionCatalog.snapshot(modules: [AlphaSchemaChangedAction])

      refute original["digest"] == changed["digest"]
    end

    test "rejects distinct modules that publish the same action name" do
      assert {:error, {:duplicate_action_name, "alpha_action"}} =
               ActionCatalog.snapshot(modules: [AlphaAction, AlphaSchemaChangedAction])
    end
  end

  describe "fetch/2 and names/1" do
    test "read the normalized snapshot without exposing aliases" do
      assert {:ok, snapshot} = ActionCatalog.snapshot(entries: @registry_entries)

      assert {:ok, alpha} = ActionCatalog.fetch(snapshot, "alpha_action")
      assert alpha["description"] == "Alpha action"
      assert :error = ActionCatalog.fetch(snapshot, "alpha.action")
      assert :error = ActionCatalog.fetch(snapshot, "missing")
      assert ActionCatalog.names(snapshot) == ["alpha_action", "zebra_action"]
    end
  end

  defp contains_runtime_value?(term)
       when is_pid(term) or is_function(term) or is_reference(term) or is_port(term),
       do: true

  defp contains_runtime_value?(term) when is_atom(term),
    do: term not in [true, false, nil]

  defp contains_runtime_value?(term) when is_list(term),
    do: Enum.any?(term, &contains_runtime_value?/1)

  defp contains_runtime_value?(term) when is_map(term),
    do:
      Enum.any?(term, fn {key, value} ->
        contains_runtime_value?(key) or contains_runtime_value?(value)
      end)

  defp contains_runtime_value?(_term), do: false
end
