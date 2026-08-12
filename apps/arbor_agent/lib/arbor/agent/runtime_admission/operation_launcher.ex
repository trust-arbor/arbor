defmodule Arbor.Agent.RuntimeAdmission.OperationLauncher do
  @moduledoc false

  @type worker_mfa :: {module(), atom(), list()}

  @doc false
  def launch(
        store_ref,
        launch_ref,
        operation_ref,
        task_supervisor,
        worker_mfa,
        begin_wait_ms
      )
      when is_reference(launch_ref) and is_reference(operation_ref) and
             is_integer(begin_wait_ms) and begin_wait_ms > 0 do
    result =
      Task.Supervisor.start_child(
        task_supervisor,
        __MODULE__,
        :run_worker,
        [launch_ref, worker_mfa, begin_wait_ms],
        []
      )

    case result do
      {:ok, worker_pid} when is_pid(worker_pid) ->
        notify(
          store_ref,
          {:runtime_admission_operation_admitted, launch_ref, operation_ref, worker_pid}
        )

      {:ok, worker_pid, _info} when is_pid(worker_pid) ->
        notify(
          store_ref,
          {:runtime_admission_operation_admitted, launch_ref, operation_ref, worker_pid}
        )

      {:error, reason} ->
        send_launch_failure(store_ref, launch_ref, operation_ref, classify_error(reason))

      _other ->
        send_launch_failure(store_ref, launch_ref, operation_ref, :admission_failed)
    end

    :ok
  rescue
    _ ->
      send_launch_failure(store_ref, launch_ref, operation_ref, :launcher_exception)
      :ok
  catch
    :exit, reason ->
      send_launch_failure(store_ref, launch_ref, operation_ref, classify_exit(reason))
      :ok

    _, _ ->
      send_launch_failure(store_ref, launch_ref, operation_ref, :launcher_error)
      :ok
  end

  @doc false
  def run_worker(launch_ref, {module, function, args}, begin_wait_ms)
      when is_reference(launch_ref) and is_atom(module) and is_atom(function) and
             is_list(args) and is_integer(begin_wait_ms) and begin_wait_ms > 0 do
    receive do
      {:runtime_admission_operation_begin, ^launch_ref} ->
        apply(module, function, args)
    after
      begin_wait_ms ->
        :ok
    end
  end

  defp send_launch_failure(store_ref, launch_ref, operation_ref, reason) do
    notify(
      store_ref,
      {:runtime_admission_operation_launch_failed, launch_ref, operation_ref, reason}
    )
  end

  @doc false
  def notify(destination, message) do
    send(destination, message)
    :ok
  rescue
    ArgumentError -> :dropped
  catch
    :error, :badarg -> :dropped
  end

  defp classify_error(:noproc), do: :supervisor_unavailable
  defp classify_error({:noproc, _}), do: :supervisor_unavailable
  defp classify_error(:timeout), do: :admission_timeout
  defp classify_error(_), do: :admission_failed

  defp classify_exit(:noproc), do: :supervisor_unavailable
  defp classify_exit({:noproc, _}), do: :supervisor_unavailable
  defp classify_exit({reason, _}) when is_tuple(reason), do: classify_exit(reason)
  defp classify_exit(_), do: :launcher_exit
end
