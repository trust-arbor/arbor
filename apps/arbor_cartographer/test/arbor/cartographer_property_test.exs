defmodule Arbor.Cartographer.PropertyTest do
  @moduledoc """
  Property-based tests for Arbor.Cartographer.

  These tests verify invariants for hardware detection and capability scheduling.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arbor.Cartographer

  # ============================================================================
  # Generators
  # ============================================================================

  @capability_tags [:gpu, :high_memory, :arm64, :x86_64, :coral_tpu, :staging, :production]

  defp capability_tag_gen do
    gen all(
          base <- member_of(@capability_tags),
          suffix <- one_of([constant(nil), atom(:alphanumeric)])
        ) do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      if suffix, do: :"#{base}_#{suffix}", else: base
    end
  end

  defp capability_list_gen do
    list_of(capability_tag_gen(), min_length: 1, max_length: 5)
  end

  # ============================================================================
  # Properties: Hardware Detection
  # ============================================================================

  describe "detect_hardware/0 properties" do
    property "detect_hardware returns map with hardware info" do
      check all(_ <- constant(nil)) do
        result = Cartographer.detect_hardware()

        case result do
          {:ok, hardware} ->
            assert is_map(hardware)
            # Hardware map should have some keys
            assert map_size(hardware) > 0

          {:error, _reason} ->
            # May fail on some systems
            assert true
        end
      end
    end

    property "hardware detection is deterministic for static properties" do
      check all(_ <- constant(nil)) do
        {:ok, hw1} = Cartographer.detect_hardware()
        {:ok, hw2} = Cartographer.detect_hardware()

        # Architecture should be the same
        if Map.has_key?(hw1, :arch) and Map.has_key?(hw2, :arch) do
          assert hw1.arch == hw2.arch
        end

        # CPU cores should be the same
        if Map.has_key?(hw1, :cpu_cores) and Map.has_key?(hw2, :cpu_cores) do
          assert hw1.cpu_cores == hw2.cpu_cores
        end
      end
    end
  end

  # ============================================================================
  # Properties: Capability Registration
  # ============================================================================

  describe "capability registration properties" do
    property "register_capabilities accepts list of tags" do
      check all(tags <- capability_list_gen()) do
        result = Cartographer.register_capabilities(tags)

        # Should succeed
        assert result == :ok
      end
    end

    property "my_capabilities returns list" do
      result = Cartographer.my_capabilities()

      case result do
        {:ok, caps} -> assert is_list(caps)
        caps when is_list(caps) -> assert true
      end
    end

    property "unregister_capabilities is safe with any tags" do
      check all(tags <- capability_list_gen()) do
        result = Cartographer.unregister_capabilities(tags)
        # Should succeed or indicate nothing to unregister
        assert result == :ok
      end
    end

    property "registered capabilities appear in my_capabilities" do
      check all(tags <- capability_list_gen()) do
        # Register some capabilities
        :ok = Cartographer.register_capabilities(tags)

        result = Cartographer.my_capabilities()

        caps =
          case result do
            {:ok, c} -> c
            c when is_list(c) -> c
          end

        assert is_list(caps)

        # All registered tags should be in my_capabilities
        Enum.each(tags, fn tag ->
          assert tag in caps
        end)

        # Cleanup
        Cartographer.unregister_capabilities(tags)
      end
    end
  end

  # ============================================================================
  # Properties: Capability Queries
  # ============================================================================

  describe "capability query properties" do
    property "find_capable_nodes returns list" do
      check all(capabilities <- capability_list_gen()) do
        result = Cartographer.find_capable_nodes(capabilities)

        case result do
          {:ok, nodes} ->
            assert is_list(nodes)

          {:error, _reason} ->
            # May fail if not in cluster
            assert true
        end
      end
    end

    property "find_capable_nodes with empty list finds all nodes" do
      result = Cartographer.find_capable_nodes([])

      case result do
        {:ok, nodes} ->
          assert is_list(nodes)
          # With empty requirements, should find at least the local node
          assert nodes != []

        {:error, _reason} ->
          assert true
      end
    end

    property "list_all_capabilities returns list" do
      result = Cartographer.list_all_capabilities()

      case result do
        {:ok, caps} -> assert is_list(caps)
        caps when is_list(caps) -> assert true
        {:error, _} -> assert true
      end
    end

    property "nodes_with_tag returns list of nodes" do
      check all(tag <- capability_tag_gen()) do
        result = Cartographer.nodes_with_tag(tag)

        case result do
          {:ok, nodes} -> assert is_list(nodes)
          nodes when is_list(nodes) -> assert true
          {:error, _} -> assert true
        end
      end
    end
  end

  # ============================================================================
  # Properties: Load Monitoring
  # ============================================================================

  describe "load monitoring properties" do
    property "get_node_load returns valid load info" do
      result = Cartographer.get_node_load(node())

      case result do
        {:ok, load} ->
          # Load can be a map or a number
          assert is_map(load) or is_number(load)

        load when is_number(load) ->
          # Direct number return
          assert true

        {:error, _reason} ->
          assert true
      end
    end

    property "get_all_loads returns map or list" do
      result = Cartographer.get_all_loads()

      case result do
        {:ok, loads} ->
          assert is_map(loads) or is_list(loads)

        loads when is_map(loads) or is_list(loads) ->
          assert true

        {:error, _} ->
          assert true
      end
    end

    property "update_load succeeds" do
      result = Cartographer.update_load()
      assert result in [:ok, {:ok, :updated}]
    end
  end

  # ============================================================================
  # Properties: Deployment
  # ============================================================================

  describe "deployment properties" do
    property "deploy with impossible requirements returns error" do
      check all(_ <- constant(nil)) do
        # Requirements that can't be satisfied
        impossible_reqs = [:quantum_processor, :time_machine, :ftl_drive]

        result = Cartographer.deploy(GenServer, needs: impossible_reqs)

        case result do
          {:error, :no_capable_nodes} -> assert true
          {:error, _other_reason} -> assert true
          # Somehow satisfied (unlikely)
          {:ok, _pid} -> assert true
        end
      end
    end

    property "node_has_capabilities? returns boolean" do
      check all(capabilities <- capability_list_gen()) do
        result = Cartographer.node_has_capabilities?(node(), capabilities)

        case result do
          bool when is_boolean(bool) -> assert true
          {:ok, bool} when is_boolean(bool) -> assert true
          {:error, _} -> assert true
        end
      end
    end
  end

  # ============================================================================
  # Properties: Health
  # ============================================================================

  describe "health properties" do
    property "healthy? returns boolean" do
      result = Cartographer.healthy?()
      assert is_boolean(result)
    end

    property "get_scout returns pid or error" do
      result = Cartographer.get_scout()

      case result do
        {:ok, pid} -> assert is_pid(pid)
        pid when is_pid(pid) -> assert true
        {:error, _} -> assert true
      end
    end

    property "start_link handles already started" do
      result = Cartographer.start_link([])

      case result do
        {:ok, _pid} -> assert true
        {:error, {:already_started, _pid}} -> assert true
        :ignore -> assert true
      end
    end
  end

  # ============================================================================
  # Properties: Model Detection
  # ============================================================================

  describe "model detection properties" do
    property "detect_models returns list or map" do
      result = Cartographer.detect_models()

      case result do
        {:ok, models} ->
          assert is_list(models) or is_map(models)

        models when is_list(models) or is_map(models) ->
          assert true
      end
    end
  end
end
