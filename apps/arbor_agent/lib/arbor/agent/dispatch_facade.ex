defmodule Arbor.Agent.DispatchFacade do
  @moduledoc false

  # Library-local implementation of authorized managed-task dispatch.
  # Public entry is Arbor.Agent.dispatch_task/4, which always passes fixed
  # Arbor.Agent.Orchestration.dispatch/3. dispatch/5 accepts a fun so unit
  # tests can inject orchestration faults without ambient hijacking.

  @max_id_bytes 256
  @max_session_token_bytes 4096
  @session_token_absent :__session_token_absent__
  @allowed_opt_keys [:session_token]
  @principal_id_re ~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/

  @type error_reason ::
          :invalid_opts
          | :invalid_caller_id
          | :invalid_agent_id
          | :invalid_task
          | :unauthorized
          | :dispatch_failed

  @doc false
  @spec dispatch(
          String.t(),
          String.t(),
          map(),
          keyword(),
          (String.t(), map(), keyword() -> term())
        ) :: {:ok, String.t()} | {:error, error_reason()}
  def dispatch(caller_id, target_agent_id, task, opts, dispatch_fun)
      when is_function(dispatch_fun, 3) do
    with {:ok, session_token} <- validate_opts(opts),
         :ok <- validate_principal_id(caller_id, :invalid_caller_id),
         :ok <- validate_principal_id(target_agent_id, :invalid_agent_id),
         :ok <- validate_task(task) do
      orch_opts = build_orch_opts(caller_id, session_token)
      invoke_dispatch(dispatch_fun, target_agent_id, task, orch_opts)
    end
  end

  defp validate_opts(opts) when not is_list(opts), do: {:error, :invalid_opts}

  defp validate_opts(opts) do
    try do
      cond do
        not Keyword.keyword?(opts) ->
          {:error, :invalid_opts}

        has_duplicate_keys?(opts) ->
          {:error, :invalid_opts}

        true ->
          case Enum.reject(Keyword.keys(opts), &(&1 in @allowed_opt_keys)) do
            [] -> extract_session_token_opt(opts)
            _unknown -> {:error, :invalid_opts}
          end
      end
    rescue
      _ -> {:error, :invalid_opts}
    catch
      :exit, _ -> {:error, :invalid_opts}
    end
  end

  defp has_duplicate_keys?(opts) do
    keys = Keyword.keys(opts)
    length(keys) != length(Enum.uniq(keys))
  end

  defp extract_session_token_opt(opts) do
    case Keyword.get_values(opts, :session_token) do
      [] ->
        {:ok, @session_token_absent}

      [token]
      when is_binary(token) and byte_size(token) > 0 and
             byte_size(token) <= @max_session_token_bytes ->
        {:ok, token}

      [_invalid] ->
        {:error, :invalid_opts}

      _duplicates ->
        {:error, :invalid_opts}
    end
  end

  defp validate_principal_id(id, error)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_id_bytes do
    if String.valid?(id) and Regex.match?(@principal_id_re, id) do
      :ok
    else
      {:error, error}
    end
  end

  defp validate_principal_id(_id, error), do: {:error, error}

  defp validate_task(task) when is_map(task) and not is_struct(task), do: :ok
  defp validate_task(_task), do: {:error, :invalid_task}

  defp build_orch_opts(caller_id, @session_token_absent), do: [caller_id: caller_id]

  defp build_orch_opts(caller_id, token) when is_binary(token),
    do: [caller_id: caller_id, session_token: token]

  defp invoke_dispatch(dispatch_fun, target_agent_id, task, orch_opts) do
    case dispatch_fun.(target_agent_id, task, orch_opts) do
      {:ok, task_id} when is_binary(task_id) and byte_size(task_id) > 0 ->
        {:ok, task_id}

      {:error, {:unauthorized, _}} ->
        {:error, :unauthorized}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, _} ->
        {:error, :dispatch_failed}

      _other ->
        {:error, :dispatch_failed}
    end
  rescue
    _ -> {:error, :dispatch_failed}
  catch
    :throw, _ -> {:error, :dispatch_failed}
    :exit, _ -> {:error, :dispatch_failed}
  end
end
