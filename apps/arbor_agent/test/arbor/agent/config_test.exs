defmodule Arbor.Agent.ConfigTest do
  # async: false because these tests mutate shared Application env for :arbor_agent.
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.Config
  alias Arbor.Agent.Orchestration.TaskRunner

  defmodule ValidExecutor do
    def run(_agent_id, _task, _context), do: {:ok, %{}}
  end

  defmodule NoRunExecutor do
    def other, do: :ok
  end

  setup do
    original_executors = Application.get_env(:arbor_agent, :task_executors)
    original_default = Application.get_env(:arbor_agent, :default_task_executor)
    original_callback_timeout = Application.get_env(:arbor_agent, :executor_callback_timeout_ms)
    original_mode = Application.get_env(:arbor_agent, :coding_executor_mode)

    on_exit(fn ->
      restore_env(:task_executors, original_executors)
      restore_env(:default_task_executor, original_default)
      restore_env(:executor_callback_timeout_ms, original_callback_timeout)
      restore_env(:coding_executor_mode, original_mode)
    end)

    :ok
  end

  test "default_task_executor/0 returns TaskRunner by default" do
    Application.delete_env(:arbor_agent, :default_task_executor)
    assert Config.default_task_executor() == TaskRunner
  end

  test "executor_callback_timeout_ms/0 has a positive default and accepts config" do
    Application.delete_env(:arbor_agent, :executor_callback_timeout_ms)
    assert Config.executor_callback_timeout_ms() == 250

    Application.put_env(:arbor_agent, :executor_callback_timeout_ms, 100)
    assert Config.executor_callback_timeout_ms() == 100

    Application.put_env(:arbor_agent, :executor_callback_timeout_ms, 0)
    assert Config.executor_callback_timeout_ms() == 250

    Application.put_env(:arbor_agent, :executor_callback_timeout_ms, "nope")
    assert Config.executor_callback_timeout_ms() == 250
  end

  test "validated_default_task_executor/0 accepts a valid configured module" do
    Application.put_env(:arbor_agent, :default_task_executor, ValidExecutor)
    assert {:ok, ValidExecutor} = Config.validated_default_task_executor()
  end

  test "validated_default_task_executor/0 rejects modules without run/3" do
    Application.put_env(:arbor_agent, :default_task_executor, NoRunExecutor)

    assert {:error, {:invalid_default_task_executor, NoRunExecutor}} =
             Config.validated_default_task_executor()
  end

  test "validated_default_task_executor/0 rejects non-module values" do
    Application.put_env(:arbor_agent, :default_task_executor, "not_a_module")

    assert {:error, {:invalid_default_task_executor, "not_a_module"}} =
             Config.validated_default_task_executor()
  end

  test "task_executors/0 defaults to empty map" do
    Application.put_env(:arbor_agent, :coding_executor_mode, :pipeline)
    Application.delete_env(:arbor_agent, :task_executors)
    assert Config.task_executors() == %{}
  end

  test "runtime coding executor selector is validated at the agent boundary" do
    Application.delete_env(:arbor_agent, :coding_executor_mode)
    assert Config.coding_executor_mode() == :pipeline
    assert Config.validate_runtime!() == :ok

    Application.put_env(:arbor_agent, :coding_executor_mode, "legacy")
    assert Config.coding_executor_mode() == :legacy
    assert Config.validate_runtime!() == :ok

    Application.put_env(:arbor_agent, :coding_executor_mode, "unknown")

    assert_raise RuntimeError, ~r/ARBOR_CODING_EXECUTOR/, fn ->
      Config.validate_runtime!()
    end
  end

  test "runtime config keeps the coding selector data-only for lower-level apps" do
    runtime_config =
      "../../../../../config/runtime.exs"
      |> Path.expand(__DIR__)
      |> File.read!()

    refute runtime_config =~ "Arbor.Agent.Config"
    refute runtime_config =~ "Arbor.Orchestrator.CodingTaskExecutor"
    refute runtime_config =~ "Arbor.Agent.Orchestration.LegacyCodingTaskExecutor"
    assert runtime_config =~ "config :arbor_agent, coding_executor_mode: coding_executor_mode"
  end

  test "legacy mode overrides only the coding_change executor" do
    Application.put_env(:arbor_agent, :coding_executor_mode, "legacy")

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => ValidExecutor,
      "other" => ValidExecutor
    })

    assert Config.task_executors()["coding_change"] ==
             Arbor.Agent.Orchestration.LegacyCodingTaskExecutor

    assert Config.task_executors()["other"] == ValidExecutor
  end

  test "task_executor/1 resolves string and atom config keys" do
    Application.put_env(:arbor_agent, :task_executors, %{
      coding_change: ValidExecutor
    })

    assert {:ok, ValidExecutor} = Config.task_executor("coding_change")
    assert {:ok, ValidExecutor} = Config.task_executor(:coding_change)

    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => ValidExecutor
    })

    assert {:ok, ValidExecutor} = Config.task_executor("coding_change")
    assert {:ok, ValidExecutor} = Config.task_executor(:coding_change)
  end

  test "task_executor/1 fails closed for blank, invalid, unsupported, and invalid modules" do
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => ValidExecutor,
      "broken" => NoRunExecutor,
      "not_a_module" => "string_value"
    })

    assert {:error, :blank_task_kind} = Config.task_executor("  ")
    assert {:error, :blank_task_kind} = Config.task_executor("")
    assert {:error, :invalid_task_kind} = Config.task_executor(123)
    assert {:error, {:unsupported_task_kind, "unknown"}} = Config.task_executor("unknown")

    assert {:error, {:invalid_task_executor, "broken", NoRunExecutor}} =
             Config.task_executor("broken")

    assert {:error, {:invalid_task_executor, "not_a_module", "string_value"}} =
             Config.task_executor("not_a_module")
  end

  test "normalize_kind/1 accepts string and atom forms" do
    assert {:ok, "coding_change"} = Config.normalize_kind("coding_change")
    assert {:ok, "coding_change"} = Config.normalize_kind(:coding_change)
    assert {:ok, "coding_change"} = Config.normalize_kind("  coding_change  ")
    assert {:error, :blank_task_kind} = Config.normalize_kind("   ")
    assert {:error, :invalid_task_kind} = Config.normalize_kind(%{})
  end

  test "configured kinded executors resolve without embedding higher-level modules" do
    # Level-7 boundary: arbor_agent must not hardcode arbor_orchestrator modules.
    # Production coding_change wiring lives in umbrella config/config.exs and is
    # asserted from arbor_commands (which may depend on both libraries).
    Application.put_env(:arbor_agent, :task_executors, %{
      "coding_change" => ValidExecutor
    })

    assert {:ok, ValidExecutor} = Config.task_executor("coding_change")
    assert {:ok, ValidExecutor} = Config.task_executor(:coding_change)
    assert function_exported?(ValidExecutor, :run, 3)

    # Plain string tasks still use the default runner, not the kinded executor.
    assert {:ok, TaskRunner} = Config.validated_default_task_executor()
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_agent, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_agent, key, value)
end
