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

    original_finalization_timeout =
      Application.get_env(:arbor_agent, :executor_finalization_timeout_ms)

    on_exit(fn ->
      restore_env(:task_executors, original_executors)
      restore_env(:default_task_executor, original_default)
      restore_env(:executor_callback_timeout_ms, original_callback_timeout)
      restore_env(:executor_finalization_timeout_ms, original_finalization_timeout)
    end)

    :ok
  end

  test "executor_finalization_timeout_ms/0 has a larger positive default and accepts config" do
    Application.delete_env(:arbor_agent, :executor_finalization_timeout_ms)
    assert Config.executor_finalization_timeout_ms() == 2_000

    Application.put_env(:arbor_agent, :executor_finalization_timeout_ms, 750)
    assert Config.executor_finalization_timeout_ms() == 750

    Application.put_env(:arbor_agent, :executor_finalization_timeout_ms, 0)
    assert Config.executor_finalization_timeout_ms() == 2_000

    Application.put_env(:arbor_agent, :executor_finalization_timeout_ms, "nope")
    assert Config.executor_finalization_timeout_ms() == 2_000
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
    Application.delete_env(:arbor_agent, :task_executors)
    assert Config.task_executors() == %{}
  end

  test "runtime config does not define a retired coding executor selector" do
    runtime_config =
      "../../../../../config/runtime.exs"
      |> Path.expand(__DIR__)
      |> File.read!()

    refute runtime_config =~ "Arbor.Agent.Config"
    refute runtime_config =~ "Arbor.Orchestrator.CodingTaskExecutor"
    refute runtime_config =~ "ARBOR_CODING_EXECUTOR"
    refute runtime_config =~ "coding_executor_mode"
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
