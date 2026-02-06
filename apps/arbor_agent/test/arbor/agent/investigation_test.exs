defmodule Arbor.Agent.InvestigationTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Investigation

  describe "start/1" do
    test "creates a new investigation from anomaly" do
      anomaly = %{
        skill: :processes,
        severity: :high,
        timestamp: DateTime.utc_now(),
        details: %{}
      }

      investigation = Investigation.start(anomaly)

      assert investigation.id =~ ~r/^inv_[a-f0-9]+$/
      assert investigation.anomaly == anomaly
      assert investigation.symptoms == []
      assert investigation.hypotheses == []
      assert investigation.confidence == 0.0
      assert length(investigation.thinking_log) == 1
    end
  end

  describe "gather_symptoms/1" do
    test "gathers system-wide symptoms" do
      anomaly = %{
        skill: :processes,
        severity: :high,
        timestamp: DateTime.utc_now(),
        details: %{}
      }

      investigation =
        anomaly
        |> Investigation.start()
        |> Investigation.gather_symptoms()

      assert length(investigation.symptoms) > 0

      # Should have memory and scheduler symptoms at minimum
      symptom_types = Enum.map(investigation.symptoms, & &1.type)
      assert :memory in symptom_types
      assert :scheduler in symptom_types
    end

    test "gathers process-specific symptoms when pid provided" do
      pid = spawn(fn -> Process.sleep(10_000) end)

      anomaly = %{
        skill: :processes,
        severity: :high,
        timestamp: DateTime.utc_now(),
        details: %{pid: pid}
      }

      investigation =
        anomaly
        |> Investigation.start()
        |> Investigation.gather_symptoms()

      # Should have process_info symptom
      symptom_types = Enum.map(investigation.symptoms, & &1.type)
      assert :process_info in symptom_types or :top_by_queue in symptom_types

      Process.exit(pid, :kill)
    end
  end

  describe "generate_hypotheses/1" do
    test "generates hypotheses for process anomaly with bloated queue" do
      # Create a process with a bloated queue
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      for _ <- 1..200, do: send(pid, :flood)

      anomaly = %{
        skill: :processes,
        severity: :high,
        timestamp: DateTime.utc_now(),
        details: %{pid: pid}
      }

      investigation =
        anomaly
        |> Investigation.start()
        |> Investigation.gather_symptoms()
        |> Investigation.generate_hypotheses()

      assert length(investigation.hypotheses) > 0
      assert investigation.selected_hypothesis != nil
      assert investigation.confidence > 0.0

      send(pid, :stop)
    end

    test "selects hypothesis with highest confidence" do
      anomaly = %{
        skill: :beam,
        severity: :medium,
        timestamp: DateTime.utc_now(),
        details: %{value: 10_000}
      }

      investigation =
        anomaly
        |> Investigation.start()
        |> Investigation.gather_symptoms()
        |> Investigation.generate_hypotheses()

      if length(investigation.hypotheses) > 1 do
        # First hypothesis should have highest confidence
        [first | rest] = investigation.hypotheses
        assert Enum.all?(rest, fn h -> h.confidence <= first.confidence end)
      end
    end
  end

  describe "to_proposal/1" do
    test "converts investigation to proposal" do
      anomaly = %{
        skill: :processes,
        severity: :high,
        timestamp: DateTime.utc_now(),
        details: %{}
      }

      investigation =
        anomaly
        |> Investigation.start()
        |> Investigation.gather_symptoms()
        |> Investigation.generate_hypotheses()

      proposal = Investigation.to_proposal(investigation)

      assert proposal.topic == :runtime_fix
      assert proposal.proposer == "debug-agent"
      assert is_binary(proposal.description)
      assert is_map(proposal.context)
      assert proposal.context.investigation_id == investigation.id
      assert is_list(proposal.context.thinking_log)
    end
  end

  describe "summary/1" do
    test "returns investigation summary" do
      anomaly = %{
        skill: :processes,
        severity: :high,
        timestamp: DateTime.utc_now(),
        details: %{}
      }

      investigation =
        anomaly
        |> Investigation.start()
        |> Investigation.gather_symptoms()
        |> Investigation.generate_hypotheses()

      summary = Investigation.summary(investigation)

      assert summary.id == investigation.id
      assert summary.anomaly_skill == :processes
      assert is_integer(summary.symptom_count)
      assert is_integer(summary.hypothesis_count)
      assert is_integer(summary.duration_ms)
    end
  end
end
