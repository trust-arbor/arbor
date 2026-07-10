defmodule Arbor.Agent.Config do
  @moduledoc """
  Application configuration for the Arbor.Agent library.

  Follows the per-library Config convention: one function per setting, reading
  from `Application.get_env/3` with safe defaults.

  ## Task executors

  Structured orchestration tasks select an executor by `kind`. Configuration
  maps kind strings (or atoms) to modules implementing
  `Arbor.Contracts.Agent.TaskExecutor`.

      config :arbor_agent,
        default_task_executor: Arbor.Agent.Orchestration.TaskRunner,
        executor_callback_timeout_ms: 250,
        task_executors: %{
          "coding_change" => MyApp.CodingPipelineExecutor
        }

  Plain strings and legacy unkinded maps use `default_task_executor/0`.
  Without an explicit runner override, both the default and kinded paths use
  the JSON-clean TaskExecutor boundary. Unknown, blank, unavailable, or
  invalid configured executors fail closed. Optional progress/cancel callbacks
  are bounded by `executor_callback_timeout_ms/0`.

  Production root wiring maps structured kinds (for example `"coding_change"`)
  to concrete TaskExecutor modules in the umbrella `config/config.exs`. This
  library must not hard-depend on higher-level executor modules; resolve them
  only via `task_executors` configuration.
  """

  @app :arbor_agent
  @default_task_executor Arbor.Agent.Orchestration.TaskRunner
  # Best-effort bound for optional task_status/2 and cancel_task/2 callbacks.
  # Short on purpose: hung executors must not freeze status or cancellation.
  @default_executor_callback_timeout_ms 250

  @doc """
  Default executor used for plain string tasks and legacy maps without `kind`.

  Prefer `validated_default_task_executor/0` before spawning work.
  """
  @spec default_task_executor() :: module()
  def default_task_executor do
    Application.get_env(@app, :default_task_executor, @default_task_executor)
  end

  @doc """
  Resolve and validate the default task executor module.

  ## Returns

    * `{:ok, module}` when a loadable module exporting `run/3` is configured
    * `{:error, {:invalid_default_task_executor, value}}` otherwise
  """
  @spec validated_default_task_executor() ::
          {:ok, module()} | {:error, {:invalid_default_task_executor, term()}}
  def validated_default_task_executor do
    module = default_task_executor()

    case validate_executor_module(module, "default") do
      {:ok, ^module} ->
        {:ok, module}

      {:error, {:invalid_task_executor, _kind, value}} ->
        {:error, {:invalid_default_task_executor, value}}
    end
  end

  @doc """
  Timeout (ms) for best-effort executor `task_status/2` and `cancel_task/2`
  callbacks invoked by TaskStore.

  Callbacks run under the task supervisor and are killed on timeout so a hung
  executor cannot freeze status probes or block cancellation.
  """
  @spec executor_callback_timeout_ms() :: pos_integer()
  def executor_callback_timeout_ms do
    case Application.get_env(
           @app,
           :executor_callback_timeout_ms,
           @default_executor_callback_timeout_ms
         ) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_executor_callback_timeout_ms
    end
  end

  @doc """
  Configured map of task kind => executor module.

  Accepts a map or keyword list from application env. Keys may be strings or
  atoms; lookup normalizes them.
  """
  @spec task_executors() :: map()
  def task_executors do
    case Application.get_env(@app, :task_executors, %{}) do
      executors when is_map(executors) -> executors
      executors when is_list(executors) -> Map.new(executors)
      _ -> %{}
    end
  end

  @doc """
  Resolve the executor module for a structured task kind.

  ## Returns

    * `{:ok, module}` when a loadable module exporting `run/3` is configured
    * `{:error, :blank_task_kind}` for empty kinds
    * `{:error, :invalid_task_kind}` for non-string/non-atom kinds
    * `{:error, {:unsupported_task_kind, kind}}` when no mapping exists
    * `{:error, {:invalid_task_executor, kind, value}}` when the mapping is not
      a valid `run/3` module

  Never falls back to the default chat executor.
  """
  @spec task_executor(term()) ::
          {:ok, module()}
          | {:error,
             :blank_task_kind
             | :invalid_task_kind
             | {:unsupported_task_kind, String.t()}
             | {:invalid_task_executor, String.t(), term()}}
  def task_executor(kind) do
    with {:ok, normalized} <- normalize_kind(kind) do
      case lookup_executor(task_executors(), normalized) do
        nil ->
          {:error, {:unsupported_task_kind, normalized}}

        module ->
          validate_executor_module(module, normalized)
      end
    end
  end

  @doc false
  @spec normalize_kind(term()) ::
          {:ok, String.t()} | {:error, :blank_task_kind | :invalid_task_kind}
  def normalize_kind(kind) when is_binary(kind) do
    case String.trim(kind) do
      "" -> {:error, :blank_task_kind}
      normalized -> {:ok, normalized}
    end
  end

  def normalize_kind(kind) when is_atom(kind) and not is_nil(kind) do
    kind
    |> Atom.to_string()
    |> normalize_kind()
  end

  def normalize_kind(_kind), do: {:error, :invalid_task_kind}

  defp lookup_executor(executors, kind) when is_map(executors) and is_binary(kind) do
    Map.get(executors, kind) ||
      Enum.find_value(executors, fn
        {key, value} when is_atom(key) ->
          if Atom.to_string(key) == kind, do: value

        {key, value} when is_binary(key) ->
          if String.trim(key) == kind, do: value

        _ ->
          nil
      end)
  end

  defp lookup_executor(_executors, _kind), do: nil

  defp validate_executor_module(module, kind) when is_atom(module) do
    cond do
      is_nil(module) ->
        {:error, {:invalid_task_executor, kind, module}}

      not Code.ensure_loaded?(module) ->
        {:error, {:invalid_task_executor, kind, module}}

      not function_exported?(module, :run, 3) ->
        {:error, {:invalid_task_executor, kind, module}}

      true ->
        {:ok, module}
    end
  end

  defp validate_executor_module(other, kind) do
    {:error, {:invalid_task_executor, kind, other}}
  end
end
