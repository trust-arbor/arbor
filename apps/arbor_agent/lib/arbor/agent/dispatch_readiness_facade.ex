defmodule Arbor.Agent.DispatchReadinessFacade do
  @moduledoc false

  # Library-local implementation of authorized coding-dispatch readiness.
  # Public entry is Arbor.Agent.coding_dispatch_readiness/4, which always passes
  # fixed Arbor.Agent.Orchestration.coding_dispatch_readiness/3. project/5
  # accepts a fun so unit tests can inject orchestration faults without ambient
  # hijacking.

  alias Arbor.Agent.Orchestration.DispatchReadinessCore

  @max_id_bytes 256
  @max_session_token_bytes 4096
  @max_timeout_ms 300_000
  @session_token_absent :__session_token_absent__
  @allowed_opt_keys [:session_token, :timeout]
  @principal_id_re ~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/

  @type error_reason ::
          :invalid_opts
          | :invalid_caller_id
          | :invalid_agent_id
          | :invalid_task
          | :unauthorized
          | :readiness_failed

  @doc false
  @spec project(
          String.t(),
          String.t(),
          map(),
          keyword(),
          (String.t(), map(), keyword() -> term())
        ) :: {:ok, map()} | {:error, error_reason()}
  def project(caller_id, target_agent_id, task, opts, project_fun)
      when is_function(project_fun, 3) do
    with {:ok, session_token, timeout} <- validate_opts(opts),
         :ok <- validate_principal_id(caller_id, :invalid_caller_id),
         :ok <- validate_principal_id(target_agent_id, :invalid_agent_id),
         :ok <- validate_task(task) do
      orch_opts = build_orch_opts(caller_id, session_token, timeout)
      invoke_project(project_fun, target_agent_id, task, orch_opts)
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
            [] ->
              with {:ok, token} <- extract_session_token_opt(opts),
                   {:ok, timeout} <- extract_timeout_opt(opts) do
                {:ok, token, timeout}
              end

            _unknown ->
              {:error, :invalid_opts}
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

  defp extract_timeout_opt(opts) do
    case Keyword.get_values(opts, :timeout) do
      [] ->
        {:ok, :absent}

      [timeout] when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout_ms ->
        {:ok, timeout}

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

  defp build_orch_opts(caller_id, @session_token_absent, :absent), do: [caller_id: caller_id]

  defp build_orch_opts(caller_id, @session_token_absent, timeout) when is_integer(timeout),
    do: [caller_id: caller_id, timeout: timeout]

  defp build_orch_opts(caller_id, token, :absent) when is_binary(token),
    do: [caller_id: caller_id, session_token: token]

  defp build_orch_opts(caller_id, token, timeout) when is_binary(token) and is_integer(timeout),
    do: [caller_id: caller_id, session_token: token, timeout: timeout]

  defp invoke_project(project_fun, target_agent_id, task, orch_opts) do
    case project_fun.(target_agent_id, task, orch_opts) do
      {:ok, report} ->
        case DispatchReadinessCore.assert_report(report) do
          {:ok, clean} -> {:ok, clean}
          {:error, _} -> {:error, :readiness_failed}
        end

      {:error, {:unauthorized, _}} ->
        {:error, :unauthorized}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, _} ->
        {:error, :readiness_failed}

      _other ->
        {:error, :readiness_failed}
    end
  rescue
    _ -> {:error, :readiness_failed}
  catch
    :throw, _ -> {:error, :readiness_failed}
    :exit, _ -> {:error, :readiness_failed}
  end
end
