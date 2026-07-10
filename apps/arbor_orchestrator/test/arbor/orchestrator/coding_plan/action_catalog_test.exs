defmodule Arbor.Orchestrator.CodingPlan.ActionCatalogTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.CodingPlan.ActionCatalog

  alias Arbor.Actions.TestFixtures.{
    AlphaAction,
    AlphaSchemaChangedAction,
    InvalidSchemaAction,
    InvalidUtf8DescriptionAction,
    InvalidUtf8NameAction,
    LongErrorAction,
    MissingDescriptionAction,
    RaisingAction,
    ZebraAction
  }

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
                 ~w(
                   beam_sha256
                   description
                   effect_class
                   egress_declared
                   egress_destination_resolver
                   egress_tier_resolver
                   module
                   name
                   parameters_schema
                   resource_uri
                 )
             end)

      assert {:ok, zebra} = ActionCatalog.fetch(snapshot, "zebra_action")

      assert zebra["parameters_schema"] == %{
               "properties" => %{"enabled" => %{"type" => "boolean"}},
               "type" => "object"
             }

      assert zebra["module"] == Atom.to_string(ZebraAction)
      assert zebra["beam_sha256"] =~ ~r/^[0-9a-f]{64}$/
      assert zebra["resource_uri"] == "arbor://action/test_fixtures/zebra_action"
      assert zebra["effect_class"] == "read"

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

    test "security regression: invalid UTF-8 names and descriptions return tagged errors" do
      assert {:error, {:invalid_action_spec, name_module, :invalid_name}} =
               ActionCatalog.snapshot(modules: [InvalidUtf8NameAction])

      assert name_module == Atom.to_string(InvalidUtf8NameAction)

      assert {:error, {:invalid_action_spec, description_module, :invalid_description}} =
               ActionCatalog.snapshot(modules: [InvalidUtf8DescriptionAction])

      assert description_module == Atom.to_string(InvalidUtf8DescriptionAction)
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
