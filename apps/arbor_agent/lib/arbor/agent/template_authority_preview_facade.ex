defmodule Arbor.Agent.TemplateAuthorityPreviewFacade do
  @moduledoc false

  # Library-local implementation of authorized template-authority preview.
  # Public entry is Arbor.Agent.template_authority_preview/3, which always
  # passes fixed Arbor.Agent.Orchestration.template_authority_preview/2.
  # project/4 accepts a fun so unit tests can inject orchestration faults
  # without ambient hijacking.

  alias Arbor.Agent.TemplateAuthorityPreviewCore

  @max_id_bytes 256
  @max_session_token_bytes 4096
  @session_token_absent :__session_token_absent__
  @allowed_opt_keys [:session_token]
  # Callers may be agents or humans; targets are agent-only principals.
  @caller_id_re ~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/
  @agent_id_re ~r/\Aagent_[A-Za-z0-9_-]+\z/

  @type error_reason ::
          :invalid_opts
          | :invalid_caller_id
          | :invalid_agent_id
          | :unauthorized
          | :preview_failed

  @doc false
  @spec project(
          String.t(),
          String.t(),
          keyword(),
          (String.t(), keyword() -> term())
        ) :: {:ok, map()} | {:error, error_reason()}
  def project(caller_id, target_agent_id, opts, project_fun)
      when is_function(project_fun, 2) do
    with {:ok, session_token} <- validate_opts(opts),
         :ok <- validate_caller_id(caller_id),
         :ok <- validate_agent_id(target_agent_id) do
      orch_opts = build_orch_opts(caller_id, session_token)
      invoke_project(project_fun, target_agent_id, orch_opts)
    end
  end

  defp validate_opts(opts) when not is_list(opts), do: {:error, :invalid_opts}

  defp validate_opts(opts) do
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

  defp validate_caller_id(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_id_bytes do
    if String.valid?(id) and Regex.match?(@caller_id_re, id) do
      :ok
    else
      {:error, :invalid_caller_id}
    end
  end

  defp validate_caller_id(_id), do: {:error, :invalid_caller_id}

  defp validate_agent_id(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_id_bytes do
    if String.valid?(id) and Regex.match?(@agent_id_re, id) do
      :ok
    else
      {:error, :invalid_agent_id}
    end
  end

  defp validate_agent_id(_id), do: {:error, :invalid_agent_id}

  # Session proofs reach Orchestration for Security.authorize/4 only.
  # The preview shell receives caller_id alone after authorization.
  defp build_orch_opts(caller_id, @session_token_absent), do: [caller_id: caller_id]

  defp build_orch_opts(caller_id, token) when is_binary(token),
    do: [caller_id: caller_id, session_token: token]

  defp invoke_project(project_fun, target_agent_id, orch_opts) do
    case project_fun.(target_agent_id, orch_opts) do
      {:ok, report} ->
        case TemplateAuthorityPreviewCore.assert_report(report) do
          {:ok, clean} -> {:ok, clean}
          {:error, _} -> {:error, :preview_failed}
        end

      {:error, {:unauthorized, _}} ->
        {:error, :unauthorized}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, _} ->
        {:error, :preview_failed}

      _other ->
        {:error, :preview_failed}
    end
  rescue
    _ -> {:error, :preview_failed}
  catch
    :throw, _ -> {:error, :preview_failed}
    :exit, _ -> {:error, :preview_failed}
  end
end
