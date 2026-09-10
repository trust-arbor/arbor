defmodule Arbor.Scheduler.OwnedRoutines do
  @moduledoc false

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.CapabilityUri

  alias Arbor.Scheduler.{
    Config,
    RoutineCatalog,
    RoutineProof,
    RoutineStore,
    RunIdentity,
    RunLease
  }

  alias Arbor.Scheduler.Cores.RoutineCore
  alias Arbor.Security
  alias Arbor.Trust

  def enqueue(intent, proof) do
    safely(fn ->
      with {:ok, intent} <- RoutineCore.intent(intent),
           {:ok, at} <- RoutineCore.scheduled_at(intent["scheduled_at"]),
           true <- RoutineCore.admissible_schedule?(at, DateTime.utc_now()),
           {:ok, owner, wire} <- RoutineProof.fresh(:enqueue, intent, proof),
           {:ok, catalog} <- catalog_for(intent),
           :ok <- owner_allowed(owner, intent, catalog),
           envelope = %{"intent" => intent, "proof" => wire},
           key = RoutineCore.digest(RoutineCore.canonical([owner, intent["request_id"]])),
           {:ok, job} <- RoutineStore.insert(envelope, key, at),
           {:ok, ^owner, stored_intent} <- job_owner(job),
           true <- stored_intent == intent do
        {:ok, project(job, owner, intent)}
      else
        false -> {:error, :routine_request_conflict}
        {:error, _} = error -> error
        _ -> {:error, :invalid_routine_request}
      end
    end)
  end

  def list(filters, proof) do
    safely(fn ->
      with {:ok, filters} <- RoutineCore.filters(filters),
           {:ok, owner, _wire} <- RoutineProof.fresh(:list, filters, proof),
           {:ok, jobs} <- RoutineStore.list(filters, owner) do
        items =
          Enum.flat_map(jobs, fn job ->
            case job_owner(job) do
              {:ok, ^owner, intent} -> [project(job, owner, intent)]
              _ -> []
            end
          end)

        {:ok,
         %{items: items, next_before_id: if(items == [], do: nil, else: List.last(items).id)}}
      end
    end)
  end

  def cancel(id, proof) do
    safely(fn ->
      with {:ok, owner, _wire} <- RoutineProof.fresh(:cancel, id, proof),
           {:ok, job} <- RoutineStore.get(id),
           {:ok, ^owner, _intent} <- job_owner(job),
           :ok <- RoutineStore.cancel(job) do
        :ok
      else
        _ -> {:error, :routine_cancel_denied}
      end
    end)
  end

  # Public preparation is non-authoritative: the returned exact intent must be
  # signed by its eventual owner, who is derived only from that signature.
  def prepare(owner, routine, at, request_id) do
    safely(fn ->
      with {:ok, catalog} <- RoutineCatalog.load(routine),
           {:ok, capabilities} <- Security.list_capabilities(owner),
           {:ok, parents} <- select_parents(catalog.resources, capabilities) do
        RoutineCore.intent(%{
          "version" => 1,
          "routine" => routine,
          "manifest_digest" => catalog.digest,
          "scheduled_at" => at,
          "request_id" => request_id,
          "parents" => parents
        })
      end
    end)
  end

  def perform(id) do
    safely(fn ->
      with {:ok, job} <- RoutineStore.get(id),
           :ok <- RoutineStore.executing(job),
           {:ok, owner, intent} <- job_owner(job),
           :ok <- intent_due(intent),
           {:ok, catalog} <- catalog_for(intent),
           :ok <- owner_allowed(owner, intent, catalog),
           token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
           {:ok, claimed_job} <- RoutineStore.claim(job, token),
           {:ok, handle} <- RunIdentity.mint(catalog.attestation) do
        try do
          binding = %{
            job: claimed_job,
            token: token,
            owner: owner,
            intent: intent,
            catalog: catalog,
            day: Date.utc_today(),
            execution_principal: handle.agent_id
          }

          with :ok <- RunLease.bind_routine(handle.lease, binding),
               :ok <- RoutineStore.current?(claimed_job, token) do
            execute(catalog, handle, %{lease: handle.lease, token: token}, claimed_job)
          end
        after
          RunIdentity.revoke(handle)
        end
      end
    end)
  end

  def check_effect(binding, effect) do
    safely(fn ->
      with :ok <- RoutineStore.current?(binding.job, binding.token),
           {:ok, owner, intent} <- job_owner(binding.job),
           :ok <- intent_due(intent),
           true <- owner == binding.owner and intent == binding.intent,
           {:ok, catalog} <- catalog_for(intent),
           true <- catalog.digest == binding.catalog.digest,
           {:ok, resource} <-
             effect_resource(
               effect,
               binding.execution_principal,
               Map.put(catalog, :day, binding.day)
             ),
           :ok <- owner_allowed(owner, intent, catalog),
           :ok <- authorize_resource(owner, resource, intent["parents"]),
           :ok <- RoutineStore.current?(binding.job, binding.token) do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :routine_effect_denied}
      end
    end)
  end

  defp execute(catalog, handle, token, job) do
    orchestrator = Config.orchestrator()

    opts = [
      graph_hash: catalog.attestation.graph_hash,
      workdir: catalog.attestation.workdir,
      initial_values: catalog.attestation.initial_args,
      author_id: catalog.attestation.issuer_id,
      run_id: "scheduler-owned-#{job.id}-#{job.attempt}",
      resumable: false,
      routine_effect_token: token,
      logs_root: Config.routine_logs_root()
    ]

    with true <-
           Code.ensure_loaded?(orchestrator) and function_exported?(orchestrator, :run_file_as, 4),
         result =
           apply(orchestrator, :run_file_as, [
             catalog.paths.path,
             handle.agent_id,
             handle.signing_authority,
             opts
           ]),
         {:ok, envelope} <- result,
         {:ok, :success} <- apply(orchestrator, :classify_run_result, [envelope]) do
      :ok
    else
      false -> {:error, :orchestrator_unavailable}
      {:error, _} = error -> error
      _ -> {:error, :routine_execution_failed}
    end
  end

  defp job_owner(%Oban.Job{
         args:
           %{
             "owned_routine" => %{"intent" => intent, "proof" => proof} = envelope,
             "request_key" => key
           } = args
       })
       when map_size(args) == 2 and map_size(envelope) == 2 do
    with {:ok, intent} <- RoutineCore.intent(intent),
         {:ok, owner} <- RoutineProof.historical(intent, proof),
         true <- key == RoutineCore.digest(RoutineCore.canonical([owner, intent["request_id"]])) do
      {:ok, owner, intent}
    else
      _ -> {:error, :invalid_owned_routine}
    end
  end

  defp job_owner(_), do: {:error, :invalid_owned_routine}

  defp intent_due(intent) do
    with {:ok, at} <- RoutineCore.scheduled_at(intent["scheduled_at"]),
         true <- DateTime.compare(at, DateTime.utc_now()) != :gt do
      :ok
    else
      _ -> {:error, :routine_not_due}
    end
  end

  defp catalog_for(intent) do
    with {:ok, catalog} <- RoutineCatalog.load(intent["routine"]),
         true <- catalog.digest == intent["manifest_digest"],
         true <-
           Enum.sort(Enum.map(intent["parents"], & &1["resource_uri"])) ==
             Enum.sort(catalog.resources) do
      {:ok, catalog}
    else
      _ -> {:error, :routine_manifest_mismatch}
    end
  end

  defp owner_allowed(owner, intent, catalog) do
    Enum.reduce_while(catalog.resources, :ok, fn resource, :ok ->
      # The parent directory is concrete; limits on the selected capability
      # are checked by Security again for each actual child-file operation.
      case authorize_resource(owner, String.trim_trailing(resource, "/**"), intent["parents"]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp authorize_resource(owner, resource, parents) do
    with parent when is_map(parent) <-
           Enum.find(parents, fn parent ->
             CapabilityUri.capability_match?(
               parent["resource_uri"],
               resource
             )
           end),
         mode when mode in [:allow, :auto] <- Trust.effective_mode(owner, resource),
         {:ok, :authorized} <-
           Security.authorize_source_owned_selected_ordinary_capability(
             owner,
             resource,
             :execute,
             parent["capability_id"],
             parent["capability_digest"]
           ) do
      :ok
    else
      _ -> {:error, :routine_owner_authority_denied}
    end
  end

  defp effect_resource(%{principal: principal, operation: :enter} = effect, principal, _catalog)
       when map_size(effect) == 2, do: {:ok, RoutineCatalog.action_uri()}

  defp effect_resource(
         %{principal: principal, operation: operation, path: path} = effect,
         principal,
         catalog
       )
       when map_size(effect) == 3 and operation in [:read, :write] and is_binary(path) do
    workdir = catalog.attestation.workdir
    relative = Path.relative_to(path, workdir)

    valid =
      case {operation, Path.split(relative)} do
        {:read, ["reports", topic, name]}
        when topic in ["upstream-deps", "upstream-deps-summary"] ->
          name == Date.to_iso8601(catalog.day) <> ".md"

        {:write, ["reports", "morning-digest", name]} ->
          name == Date.to_iso8601(catalog.day) <> ".md" or
            Regex.match?(~r/\A\.arbor-digest-[0-9a-f]{32}\.tmp\z/, name)

        _ ->
          false
      end

    if valid and Path.expand(relative, workdir) == path,
      do: {:ok, RoutineCatalog.file_uri(operation, path)},
      else: {:error, :routine_effect_outside_catalog}
  end

  defp effect_resource(_, _, _), do: {:error, :invalid_routine_effect}

  defp select_parents(resources, capabilities) do
    Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, parents} ->
      case Enum.find(
             capabilities,
             &(supported?(&1) and Security.capability_authorizes?(&1, resource))
           ) do
        nil ->
          {:halt, {:error, :routine_parent_capability_missing}}

        cap ->
          {:cont,
           {:ok,
            parents ++
              [
                %{
                  "resource_uri" => resource,
                  "capability_id" => cap.id,
                  "capability_digest" => RoutineCore.digest(Capability.signing_payload(cap))
                }
              ]}}
      end
    end)
  end

  defp supported?(%Capability{
         parent_capability_id: nil,
         delegation_chain: [],
         session_id: nil,
         task_id: nil,
         principal_scope: nil,
         max_uses: nil,
         constraints: constraints
       }),
       do: constraints == %{}

  defp supported?(_), do: false

  defp project(job, owner, intent) do
    %{
      id: job.id,
      owner: owner,
      routine: intent["routine"],
      request_id: intent["request_id"],
      scheduled_at: intent["scheduled_at"],
      state: job.state,
      attempt: job.attempt
    }
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, :routine_unavailable}
  catch
    _, _ -> {:error, :routine_unavailable}
  end
end
