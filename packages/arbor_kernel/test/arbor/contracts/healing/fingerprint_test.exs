defmodule Arbor.Contracts.Healing.FingerprintTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Healing.Fingerprint

  describe "from_anomaly/1" do
    test "creates fingerprint from valid anomaly with value above ewma" do
      anomaly = %{
        skill: :memory,
        details: %{
          metric: :total_bytes,
          value: 1_000_000,
          ewma: 800_000,
          stddev: 50_000
        }
      }

      assert {:ok, fp} = Fingerprint.from_anomaly(anomaly)
      assert fp.skill == :memory
      assert fp.metric == :total_bytes
      assert fp.direction == :above
      assert is_integer(fp.hash)
    end

    test "creates fingerprint from valid anomaly with value below ewma" do
      anomaly = %{
        skill: :ets,
        details: %{
          metric: :table_count,
          value: 100,
          ewma: 150,
          stddev: 10
        }
      }

      assert {:ok, fp} = Fingerprint.from_anomaly(anomaly)
      assert fp.skill == :ets
      assert fp.metric == :table_count
      assert fp.direction == :below
    end

    test "returns error for missing metric" do
      anomaly = %{
        skill: :memory,
        details: %{
          value: 1_000_000,
          ewma: 800_000
        }
      }

      assert {:error, :missing_metric} = Fingerprint.from_anomaly(anomaly)
    end

    test "returns error for missing value" do
      anomaly = %{
        skill: :memory,
        details: %{
          metric: :total_bytes,
          ewma: 800_000
        }
      }

      assert {:error, :missing_value_or_ewma} = Fingerprint.from_anomaly(anomaly)
    end

    test "returns error for missing ewma" do
      anomaly = %{
        skill: :memory,
        details: %{
          metric: :total_bytes,
          value: 1_000_000
        }
      }

      assert {:error, :missing_value_or_ewma} = Fingerprint.from_anomaly(anomaly)
    end

    test "returns error for invalid format" do
      assert {:error, :invalid_anomaly_format} = Fingerprint.from_anomaly(%{})
      assert {:error, :invalid_anomaly_format} = Fingerprint.from_anomaly(nil)
      assert {:error, :invalid_anomaly_format} = Fingerprint.from_anomaly(%{skill: :test})
    end
  end

  describe "new/3" do
    test "creates fingerprint directly" do
      fp = Fingerprint.new(:beam, :process_count, :above)

      assert fp.skill == :beam
      assert fp.metric == :process_count
      assert fp.direction == :above
      assert is_integer(fp.hash)
    end
  end

  describe "equal?/2" do
    test "returns true for identical fingerprints" do
      fp1 = Fingerprint.new(:memory, :total, :above)
      fp2 = Fingerprint.new(:memory, :total, :above)

      assert Fingerprint.equal?(fp1, fp2)
    end

    test "returns false for different skill" do
      fp1 = Fingerprint.new(:memory, :total, :above)
      fp2 = Fingerprint.new(:ets, :total, :above)

      refute Fingerprint.equal?(fp1, fp2)
    end

    test "returns false for different metric" do
      fp1 = Fingerprint.new(:memory, :total, :above)
      fp2 = Fingerprint.new(:memory, :heap, :above)

      refute Fingerprint.equal?(fp1, fp2)
    end

    test "returns false for different direction" do
      fp1 = Fingerprint.new(:memory, :total, :above)
      fp2 = Fingerprint.new(:memory, :total, :below)

      refute Fingerprint.equal?(fp1, fp2)
    end
  end

  describe "hash/1" do
    test "returns consistent hash for same fingerprint" do
      fp1 = Fingerprint.new(:beam, :schedulers, :above)
      fp2 = Fingerprint.new(:beam, :schedulers, :above)

      assert Fingerprint.hash(fp1) == Fingerprint.hash(fp2)
    end

    test "returns different hash for different fingerprints" do
      fp1 = Fingerprint.new(:beam, :schedulers, :above)
      fp2 = Fingerprint.new(:beam, :schedulers, :below)

      refute Fingerprint.hash(fp1) == Fingerprint.hash(fp2)
    end
  end

  describe "family_hash/1" do
    test "returns same hash for same skill+metric regardless of direction" do
      fp1 = Fingerprint.new(:memory, :heap, :above)
      fp2 = Fingerprint.new(:memory, :heap, :below)

      assert Fingerprint.family_hash(fp1) == Fingerprint.family_hash(fp2)
    end

    test "returns different hash for different skill+metric" do
      fp1 = Fingerprint.new(:memory, :heap, :above)
      fp2 = Fingerprint.new(:memory, :stack, :above)

      refute Fingerprint.family_hash(fp1) == Fingerprint.family_hash(fp2)
    end
  end

  describe "to_string/1" do
    test "returns readable string representation" do
      fp = Fingerprint.new(:ets, :table_count, :above)

      assert Fingerprint.to_string(fp) == "ets:table_count:above"
    end
  end
end
