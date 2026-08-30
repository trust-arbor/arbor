defmodule Arbor.Orchestrator.CodingRunRecovery do
  @moduledoc """
  Imperative shell for coding-run recovery credentials and coordinator skip.

  Never persists SigningAuthority values. Production
  `resolve_coordinator_options/1` never opens an authority.
  """

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.CodingPlan.ArtifactStore
  alias Arbor.Orchestrator.Config
  alias Arbor.Orchestrator.RunLifecycle.Record

  @spec resolve_coordinator_options(Record.t()) ::
          {:skip, :task_store_owned} | {:error, :authentication_unavailable}
  def resolve_coordinator_options(%Record{} = record) do
    case task_owned?(record) do
      {:skip, :task_store_owned} = skip ->
        skip

      {:error, :authentication_unavailable} = error ->
        error
    end
  end

  def resolve_coordinator_options(_), do: {:error, :authentication_unavailable}

  @spec task_owned?(Record.t()) ::
          {:skip, :task_store_owned} | {:error, :authentication_unavailable}
  def task_owned?(%Record{} = record) do
    case read_ownership(record) do
      {:ok, :owned} -> {:skip, :task_store_owned}
      {:error, :unavailable} -> {:skip, :task_store_owned}
      {:error, _} -> {:error, :authentication_unavailable}
    end
  end

  def task_owned?(_), do: {:error, :authentication_unavailable}

  @spec acquire_resume_authority(String.t()) ::
          {:ok, SigningAuthority.t(), module()} | {:error, term()}
  def acquire_resume_authority(principal_id)
      when is_binary(principal_id) and principal_id != "" do
    case security_facade() do
      {:ok, security} ->
        case open_resume_authority(security, principal_id) do
          {:ok, opened} ->
            finish_resume_authority(security, opened, principal_id)

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  def acquire_resume_authority(_), do: {:error, :authentication_unavailable}

  @spec close_authority(module(), term()) :: :ok | {:error, term()}
  def close_authority(security, authority) when is_atom(security) do
    case security.close_signing_authority(authority) do
      :ok -> :ok
      {:error, _} = error -> error
      other -> {:error, {:unexpected_close_result, other}}
    end
  rescue
    exception -> {:error, {:authority_close_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:authority_close_failed, {kind, reason}}}
  end

  def close_authority(_security, _authority), do: {:error, :security_unavailable}

  defp open_resume_authority(security, principal_id) do
    with {:ok, private_key} <- security.load_signing_key(principal_id),
         true <- is_binary(private_key) and private_key != "",
         {:ok, proof} <-
           security.build_signing_authority_acquisition_proof(
             principal_id,
             private_key,
             purpose: :coding_task_recovery,
             owner: self()
           ),
         {:ok, opened} <- security.open_signing_authority(proof) do
      {:ok, opened}
    else
      false -> {:error, :invalid_signing_key}
      {:error, :no_signing_key} -> {:error, :authentication_unavailable}
      {:error, :broker_unavailable} -> {:error, :broker_unavailable}
      {:error, :security_unavailable} -> {:error, :security_unavailable}
      {:error, reason} -> {:error, {:signing_authority_acquisition_failed, reason}}
      other -> {:error, {:signing_authority_acquisition_failed, other}}
    end
  rescue
    exception ->
      {:error, {:signing_authority_acquisition_failed, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:signing_authority_acquisition_failed, {kind, reason}}}
  end

  defp finish_resume_authority(security, opened, principal_id) do
    result =
      try do
        case SigningAuthority.canonicalize(opened) do
          {:ok, %SigningAuthority{principal_id: ^principal_id} = authority} ->
            {:ok, authority, security}

          {:ok, %SigningAuthority{}} ->
            {:error, :principal_mismatch}

          {:error, reason} ->
            {:error, {:signing_authority_acquisition_failed, reason}}
        end
      rescue
        exception ->
          {:error, {:signing_authority_acquisition_failed, Exception.message(exception)}}
      catch
        kind, reason ->
          {:error, {:signing_authority_acquisition_failed, {kind, reason}}}
      end

    case result do
      {:ok, _authority, _security} ->
        result

      {:error, reason} ->
        Arbor.Orchestrator.CodingPlan.CodingRunRecoveryCore.combine_close_result(
          close_authority(security, opened),
          {:error, reason}
        )
    end
  end

  defp read_ownership(%Record{run_id: run_id} = record) when is_binary(run_id) do
    case coding_task_root(run_id) do
      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, :not_coding_root} ->
        if coding_shaped_logs_root?(record.logs_root) do
          {:error, :unavailable}
        else
          {:error, :not_found}
        end

      {:ok, root} ->
        case ArtifactStore.read_run_binding(root) do
          {:ok, binding} ->
            match_ownership(binding, record)

          {:error, :not_found} ->
            {:error, :not_found}

          {:error, :malformed} ->
            {:error, :malformed}

          {:error, :unavailable} ->
            {:error, :unavailable}

          {:error, _} ->
            {:error, :unavailable}
        end
    end
  end

  defp read_ownership(_), do: {:error, :not_found}

  defp match_ownership(binding, %Record{} = record) do
    graph_hash = record.graph_hash
    principal = record.execution_principal
    run_id = record.run_id

    if is_map(binding) and binding["run_id"] == run_id and
         binding["execution_principal"] == principal and
         binding["graph_hash"] == graph_hash do
      {:ok, :owned}
    else
      {:error, :malformed}
    end
  end

  defp coding_task_root(run_id) when is_binary(run_id) do
    digest =
      :crypto.hash(:sha256, run_id)
      |> Base.encode16(case: :lower)

    case coding_logs_base() do
      {:ok, base} ->
        case SafePath.safe_join(base, "task-" <> digest) do
          {:ok, root} ->
            case File.lstat(root) do
              {:ok, %File.Stat{type: :directory}} ->
                {:ok, root}

              {:ok, _} ->
                {:error, :not_coding_root}

              {:error, :enoent} ->
                {:error, :not_coding_root}

              {:error, _} ->
                {:error, :unavailable}
            end

          {:error, _} ->
            {:error, :not_coding_root}
        end

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, _} ->
        {:error, :not_coding_root}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp coding_logs_base do
    configured = Config.coding_pipeline_logs_root()

    with true <- is_binary(configured) and configured != "",
         expanded = Path.expand(configured),
         {:ok, canonical} <- SafePath.resolve_real(expanded),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      {:error, :enoent} -> {:error, :not_coding_root}
      {:error, _} -> {:error, :unavailable}
      false -> {:error, :not_coding_root}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp coding_shaped_logs_root?(logs_root) when is_binary(logs_root) do
    case coding_logs_base() do
      {:ok, base} ->
        case SafePath.resolve_real(Path.expand(logs_root)) do
          {:ok, real} -> SafePath.within?(real, base)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp coding_shaped_logs_root?(_), do: false

  defp security_facade do
    security = Config.security_module()

    if is_atom(security) and Code.ensure_loaded?(security) and
         function_exported?(security, :load_signing_key, 1) and
         function_exported?(security, :build_signing_authority_acquisition_proof, 3) and
         function_exported?(security, :open_signing_authority, 1) and
         function_exported?(security, :close_signing_authority, 1) do
      {:ok, security}
    else
      {:error, :security_unavailable}
    end
  end
end
