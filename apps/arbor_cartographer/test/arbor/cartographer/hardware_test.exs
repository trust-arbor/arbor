defmodule Arbor.Cartographer.HardwareTest do
  use ExUnit.Case, async: true

  alias Arbor.Cartographer.Hardware

  @moduletag :fast

  describe "detect/0" do
    test "returns hardware info with all expected keys" do
      {:ok, info} = Hardware.detect()

      assert Map.has_key?(info, :arch)
      assert Map.has_key?(info, :cpus)
      assert Map.has_key?(info, :memory_gb)
      assert Map.has_key?(info, :gpu)
      assert Map.has_key?(info, :accelerators)
    end

    test "detects valid architecture" do
      {:ok, info} = Hardware.detect()
      assert info.arch in [:x86_64, :arm64, :arm32, :unknown]
    end

    test "detects positive CPU count" do
      {:ok, info} = Hardware.detect()
      assert is_integer(info.cpus)
      assert info.cpus > 0
    end

    test "detects positive memory" do
      {:ok, info} = Hardware.detect()
      assert is_float(info.memory_gb)
      assert info.memory_gb > 0
    end

    test "accelerators is a list" do
      {:ok, info} = Hardware.detect()
      assert is_list(info.accelerators)
    end
  end

  describe "detect_arch/0" do
    test "returns atom architecture" do
      arch = Hardware.detect_arch()
      assert arch in [:x86_64, :arm64, :arm32, :unknown]
    end
  end

  describe "detect_cpus/0" do
    test "returns positive integer" do
      cpus = Hardware.detect_cpus()
      assert is_integer(cpus)
      assert cpus > 0
    end

    test "matches System.schedulers_online/0" do
      assert Hardware.detect_cpus() == System.schedulers_online()
    end
  end

  describe "detect_memory_gb/0" do
    test "returns positive float" do
      memory = Hardware.detect_memory_gb()
      assert is_float(memory)
      assert memory > 0
    end

    test "returns reasonable value (at least 0.1 GB)" do
      memory = Hardware.detect_memory_gb()
      assert memory >= 0.1
    end
  end

  describe "detect_gpus/0" do
    test "returns list or nil" do
      gpus = Hardware.detect_gpus()
      assert is_nil(gpus) or is_list(gpus)
    end

    test "GPU info has required fields when present" do
      case Hardware.detect_gpus() do
        nil ->
          :ok

        gpus ->
          for gpu <- gpus do
            assert Map.has_key?(gpu, :type)
            assert Map.has_key?(gpu, :name)
            assert Map.has_key?(gpu, :vram_gb)
            assert gpu.type in [:nvidia, :amd, :intel, :apple]
            assert is_binary(gpu.name)
            assert is_float(gpu.vram_gb) or is_integer(gpu.vram_gb)
          end
      end
    end
  end

  describe "detect_accelerators/0" do
    test "returns a list" do
      accelerators = Hardware.detect_accelerators()
      assert is_list(accelerators)
    end

    test "accelerator info has required fields when present" do
      for accel <- Hardware.detect_accelerators() do
        assert Map.has_key?(accel, :type)
        assert is_atom(accel.type)
      end
    end
  end

  describe "to_capability_tags/1" do
    test "includes architecture tag" do
      {:ok, info} = Hardware.detect()
      tags = Hardware.to_capability_tags(info)

      # Should have at least the arch tag (or empty if unknown)
      if info.arch != :unknown do
        assert info.arch in tags
      end
    end

    test "includes :high_memory tag when memory >= 32GB" do
      info = %{
        arch: :x86_64,
        cpus: 8,
        memory_gb: 64.0,
        gpu: nil,
        accelerators: []
      }

      tags = Hardware.to_capability_tags(info)
      assert :high_memory in tags
    end

    test "excludes :high_memory tag when memory < 32GB" do
      info = %{
        arch: :x86_64,
        cpus: 8,
        memory_gb: 16.0,
        gpu: nil,
        accelerators: []
      }

      tags = Hardware.to_capability_tags(info)
      refute :high_memory in tags
    end

    test "includes :gpu tag when GPU is present" do
      info = %{
        arch: :x86_64,
        cpus: 8,
        memory_gb: 16.0,
        gpu: [%{type: :nvidia, name: "RTX 3080", vram_gb: 10.0}],
        accelerators: []
      }

      tags = Hardware.to_capability_tags(info)
      assert :gpu in tags
      assert :nvidia_gpu in tags
    end

    test "includes :gpu_vram_24gb tag when GPU has >= 24GB VRAM" do
      info = %{
        arch: :x86_64,
        cpus: 8,
        memory_gb: 16.0,
        gpu: [%{type: :nvidia, name: "RTX 4090", vram_gb: 24.0}],
        accelerators: []
      }

      tags = Hardware.to_capability_tags(info)
      assert :gpu_vram_24gb in tags
    end

    test "includes accelerator tags when present" do
      info = %{
        arch: :x86_64,
        cpus: 8,
        memory_gb: 16.0,
        gpu: nil,
        accelerators: [%{type: :coral_tpu, device: "/dev/apex_0"}]
      }

      tags = Hardware.to_capability_tags(info)
      assert :coral_tpu in tags
    end

    test "returns unique tags" do
      {:ok, info} = Hardware.detect()
      tags = Hardware.to_capability_tags(info)

      assert tags == Enum.uniq(tags)
    end
  end
end
