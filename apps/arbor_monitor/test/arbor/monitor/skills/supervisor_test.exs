defmodule Arbor.Monitor.Skills.SupervisorTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Monitor.Skills.Supervisor, as: SupervisorSkill

  describe "name/0" do
    test "returns :supervisor" do
      assert SupervisorSkill.name() == :supervisor
    end
  end

  describe "collect/0" do
    test "returns expected keys with valid types" do
      assert {:ok, metrics} = SupervisorSkill.collect()

      assert is_integer(metrics.supervisor_count)
      assert is_integer(metrics.total_specs)
      assert is_integer(metrics.total_active)
      assert is_list(metrics.supervisors)
    end

    test "supervisor entries have required fields" do
      assert {:ok, metrics} = SupervisorSkill.collect()

      Enum.each(metrics.supervisors, fn sup ->
        assert Map.has_key?(sup, :name)
        assert Map.has_key?(sup, :pid)
        assert Map.has_key?(sup, :specs)
        assert Map.has_key?(sup, :active)
        assert Map.has_key?(sup, :workers)
        assert Map.has_key?(sup, :supervisors)
        assert is_binary(sup.pid)
        assert is_integer(sup.specs)
        assert is_integer(sup.active)
      end)
    end

    test "total_active does not exceed total_specs" do
      assert {:ok, metrics} = SupervisorSkill.collect()
      assert metrics.total_active <= metrics.total_specs
    end
  end

  describe "check/1" do
    test "returns :normal when all children are active" do
      metrics = %{
        supervisors: [
          %{name: :test_sup, specs: 3, active: 3}
        ]
      }

      assert :normal = SupervisorSkill.check(metrics)
    end

    test "detects inactive children" do
      metrics = %{
        supervisors: [
          %{name: :healthy_sup, specs: 3, active: 3},
          %{name: :unhealthy_sup, specs: 5, active: 2}
        ]
      }

      assert {:anomaly, :warning, details} = SupervisorSkill.check(metrics)
      assert details.metric == :supervisor_inactive_children
      assert length(details.supervisors) == 1
      assert hd(details.supervisors).name == :unhealthy_sup
    end
  end
end
