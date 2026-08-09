defmodule Arbor.Agent.Orchestration.DispatchReadiness do
  @moduledoc false

  # Imperative shell for Agent-owned coding-dispatch readiness.
  # Fixed production collaborators only on the public path. Tests may inject
  # via project_with_deps/4; public opts never select modules/clocks/stores.

  alias Arbor.Agent.Config
  alias Arbor.Agent.ExactTemplatePolicy
  alias Arbor.Agent.Lifecycle
  alias Arbor.Agent.Orchestration.DispatchReadinessCore, as: Core
  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Agent.ProfileStore
  alias Arbor.Agent.TemplateStore
  alias Arbor.Security

  @required_grants Core.required_grants()

  @type deps :: %{
          optional(:security) => module(),
          optional(:lifecycle) => module(),
          optional(:profile_store) => module(),
          optional(:template_store) => module(),
          optional(:task_store) => module(),
          optional(:config) => module(),
          optional(:exact_policy) => module(),
          optional(:clock) => (-> DateTime.t()),
          optional(:callback_timeout_ms) => pos_integer(),
          optional(:invoke_executor) =>
            (module(), String.t(), term(), map(), pos_integer() -> term())
        }

  @spec project(String.t(), term(), keyword() | map()) :: {:ok, map()}
  def project(agent_id, task, opts \\ []) do
    project_with_deps(agent_id, task, opts, production_deps())
  end

  @doc false
  @spec project_with_deps(String.t(), term(), keyword() | map(), deps()) :: {:ok, map()}
  def project_with_deps(agent_id, task, opts, deps) when is_map(deps) do
    deps = Map.merge(production_deps(), deps)
    caller_id = opt(opts, :caller_id)
    timeout = opt(opts, :timeout)

    try do
      observed_at = observe_at(deps.clock)

      security_facts = gather_security(deps, caller_id)
      security_plane = Core.project_security(security_facts)

      coordinator_plane = Core.project_coordinator(gather_coordinator(deps, agent_id))
      exact_plane = Core.project_exact_template(gather_exact_template(deps, agent_id))

      task_control_plane =
        Core.project_task_control(Map.merge(security_facts, gather_task_control(deps)))

      executor_plane =
        Core.project_executor(gather_executor(deps, agent_id, task, caller_id, timeout))

      case Core.compose(%{
             observed_at: observed_at,
             agent_id: agent_id,
             caller_id: caller_id,
             security: security_plane,
             coordinator: coordinator_plane,
             exact_template: exact_plane,
             task_control: task_control_plane,
             executor: executor_plane
           }) do
        {:ok, report} ->
          {:ok, report}

        {:error, _} ->
          {:ok,
           Core.error_report(
             observed_at: observed_at,
             agent_id: agent_id,
             caller_id: caller_id,
             code: "malformed_plane_input",
             message: "dispatch readiness could not compose planes"
           )}
      end
    rescue
      _ ->
        {:ok,
         Core.error_report(
           observed_at: nil,
           agent_id: agent_id,
           caller_id: caller_id,
           code: "projection_failed",
           message: "dispatch readiness failed closed"
         )}
    catch
      _, _ ->
        {:ok,
         Core.error_report(
           observed_at: nil,
           agent_id: agent_id,
           caller_id: caller_id,
           code: "projection_failed",
           message: "dispatch readiness failed closed"
         )}
    end
  end

  defp production_deps do
    %{
      security: Security,
      lifecycle: Lifecycle,
      profile_store: ProfileStore,
      template_store: TemplateStore,
      task_store: TaskStore,
      config: Config,
      exact_policy: ExactTemplatePolicy,
      clock: &DateTime.utc_now/0,
      callback_timeout_ms: Config.executor_callback_timeout_ms(),
      invoke_executor: &default_invoke_executor/5
    }
  end

  defp observe_at(clock) when is_function(clock, 0) do
    case clock.() do
      %DateTime{} = dt -> DateTime.to_iso8601(dt, :extended)
      other when is_binary(other) -> other
      _ -> nil
    end
  end

  defp observe_at(_), do: nil

  # ---------------------------------------------------------------------------
  # Fact gatherers (reads only)
  # ---------------------------------------------------------------------------

  defp gather_security(deps, caller_id) do
    security = deps.security

    healthy? =
      try do
        security.healthy?() == true
      rescue
        _ -> false
      catch
        _, _ -> false
      end

    with {:ok, stats} <- fetch_stats(security),
         {:ok, cap_stats} <- fetch_cap_stats(stats),
         {:ok, enforcement} <- fetch_enforcement(cap_stats),
         {:ok, active_capabilities} <-
           fetch_required_non_neg(cap_stats, :active_capabilities, "active_capabilities"),
         {:ok, max_global} <-
           fetch_required_positive(cap_stats, :quota_max_global, "quota_max_global"),
         {:ok, max_per} <-
           fetch_required_positive(cap_stats, :quota_max_per_agent, "quota_max_per_agent"),
         {:ok, principal_indexed_count} <- fetch_principal_indexed_count(security, caller_id) do
      %{
        facts_available?: true,
        healthy?: healthy?,
        restore_status: if(healthy?, do: "ready", else: "failed"),
        restore_scanned: optional_non_neg(cap_stats, :restore_scanned, "restore_scanned"),
        restore_active: optional_non_neg(cap_stats, :restore_active, "restore_active"),
        restore_expired: optional_non_neg(cap_stats, :restore_expired, "restore_expired"),
        restore_superseded: optional_non_neg(cap_stats, :restore_superseded, "restore_superseded"),
        restore_rejected: optional_non_neg(cap_stats, :restore_rejected, "restore_rejected"),
        quota_enforcement_enabled?: enforcement,
        active_capabilities: active_capabilities,
        max_global: max_global,
        max_per_principal: max_per,
        principal_indexed_count: principal_indexed_count
      }
    else
      {:error, reason} ->
        unavailable_security_facts(healthy?, reason)
    end
  end

  defp unavailable_security_facts(healthy?, reason) do
    %{
      facts_available?: false,
      healthy?: healthy?,
      restore_status: "unavailable",
      restore_scanned: 0,
      restore_active: 0,
      restore_expired: 0,
      restore_superseded: 0,
      restore_rejected: 0,
      quota_enforcement_enabled?: :unavailable,
      active_capabilities: :unavailable,
      max_global: :unavailable,
      max_per_principal: :unavailable,
      principal_indexed_count: :unavailable,
      facts_error: reason
    }
  end

  defp fetch_stats(security) do
    case security.stats() do
      stats when is_map(stats) -> {:ok, stats}
      _ -> {:error, :stats_unavailable}
    end
  rescue
    _ -> {:error, :stats_unavailable}
  catch
    _, _ -> {:error, :stats_unavailable}
  end

  defp fetch_cap_stats(stats) do
    case Map.get(stats, :capabilities) || Map.get(stats, "capabilities") do
      cap_stats when is_map(cap_stats) and map_size(cap_stats) > 0 -> {:ok, cap_stats}
      _ -> {:error, :capability_stats_unavailable}
    end
  end

  defp fetch_enforcement(cap_stats) do
    case Map.fetch(cap_stats, :quota_enforcement_enabled) do
      {:ok, true} ->
        {:ok, true}

      {:ok, false} ->
        {:ok, false}

      :error ->
        case Map.fetch(cap_stats, "quota_enforcement_enabled") do
          {:ok, true} -> {:ok, true}
          {:ok, false} -> {:ok, false}
          _ -> {:error, :quota_enforcement_unavailable}
        end

      _ ->
        {:error, :quota_enforcement_unavailable}
    end
  end

  defp fetch_required_non_neg(map, atom_key, string_key) do
    case Map.get(map, atom_key) || Map.get(map, string_key) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, {:missing_stat, string_key}}
    end
  end

  defp fetch_required_positive(map, atom_key, string_key) do
    case Map.get(map, atom_key) || Map.get(map, string_key) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, {:missing_stat, string_key}}
    end
  end

  defp optional_non_neg(map, atom_key, string_key) do
    case Map.get(map, atom_key) || Map.get(map, string_key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp fetch_principal_indexed_count(_security, caller_id)
       when not is_binary(caller_id) or caller_id == "" do
    {:error, :caller_id_required_for_quota}
  end

  defp fetch_principal_indexed_count(security, principal_id) do
    # Match CapabilityStore.check_per_agent_limit/2: count by_principal entries
    # including expired-until-removed. Default list filters expired.
    case security.list_capabilities(principal_id, include_expired: true) do
      {:ok, caps} when is_list(caps) -> {:ok, length(caps)}
      _ -> {:error, :principal_enumerate_failed}
    end
  rescue
    _ -> {:error, :principal_enumerate_failed}
  catch
    _, _ -> {:error, :principal_enumerate_failed}
  end

  defp gather_coordinator(deps, agent_id) do
    # Only Lifecycle.get_host/1 returning {:error, :no_host} is ordinary absence.
    # Every other error tuple, bare :error, nil, or malformed return is infrastructure
    # failure and projects coordinator status error (not absent/blocked).
    host_state =
      try do
        case deps.lifecycle.get_host(agent_id) do
          {:ok, pid} when is_pid(pid) ->
            if Process.alive?(pid), do: "running", else: "not_alive"

          {:error, :no_host} ->
            "absent"

          {:error, _} ->
            "error"

          :error ->
            "error"

          nil ->
            "error"

          _malformed ->
            "error"
        end
      rescue
        _ -> "error"
      catch
        _, _ -> "error"
      end

    %{host_state: host_state}
  end

  defp gather_exact_template(deps, agent_id) do
    policy = deps.exact_policy
    profiles = deps.profile_store
    templates = deps.template_store

    with :ok <- require_exported(profiles, :load_profile_readonly, 1),
         :ok <- require_exported(templates, :get_current, 1),
         {:ok, profile} <- profiles.load_profile_readonly(agent_id),
         {:ok, template_name} <- template_name(profile) do
      metadata = profile.metadata || %{}

      case policy.from_metadata(metadata) do
        :not_marked ->
          %{
            template_state: "unmanaged",
            template_name: template_name,
            managed: false,
            stored_digest_present: false,
            digest_match: nil,
            source_layer: nil
          }

        {:error, _} ->
          %{
            template_state: "invalid",
            template_name: template_name,
            managed: true,
            stored_digest_present: false,
            digest_match: nil,
            source_layer: nil
          }

        {:ok, stored} ->
          compare_managed_template(policy, templates, template_name, stored)
      end
    else
      {:error, :missing_readonly_collaborator} ->
        %{
          template_state: "unavailable",
          template_name: nil,
          managed: false,
          stored_digest_present: false,
          digest_match: nil,
          source_layer: nil
        }

      {:error, :not_found} ->
        %{
          template_state: "unavailable",
          template_name: nil,
          managed: false,
          stored_digest_present: false,
          digest_match: nil,
          source_layer: nil
        }

      {:error, :invalid_template_name} ->
        %{
          template_state: "invalid",
          template_name: nil,
          managed: false,
          stored_digest_present: false,
          digest_match: nil,
          source_layer: nil
        }

      _ ->
        %{
          template_state: "unavailable",
          template_name: nil,
          managed: false,
          stored_digest_present: false,
          digest_match: nil,
          source_layer: nil
        }
    end
  end

  defp compare_managed_template(policy, templates, template_name, stored) do
    stored_digest = policy.digest(stored)

    case templates.get_current(template_name) do
      {:ok, data} ->
        layer = source_layer_from(data)

        repo_root =
          case policy.snapshot(stored) do
            %{"repo_root" => root} -> root
            _ -> nil
          end

        build_opts = if is_binary(repo_root), do: [repo_root: repo_root], else: []

        case policy.build(template_name, data, build_opts) do
          {:ok, current} ->
            digests_match? = policy.digest(stored) == policy.digest(current)
            closed_source? = layer in ["user", "shipped", "legacy_json"]

            template_state =
              cond do
                digests_match? and closed_source? -> "current"
                digests_match? -> "invalid"
                true -> "drifted"
              end

            %{
              template_state: template_state,
              template_name: template_name,
              managed: true,
              stored_digest_present: is_binary(stored_digest),
              digest_match: digests_match?,
              source_layer: layer
            }

          :not_exact ->
            %{
              template_state: "invalid",
              template_name: template_name,
              managed: true,
              stored_digest_present: is_binary(stored_digest),
              digest_match: false,
              source_layer: layer
            }

          {:error, _} ->
            %{
              template_state: "invalid",
              template_name: template_name,
              managed: true,
              stored_digest_present: is_binary(stored_digest),
              digest_match: false,
              source_layer: layer
            }
        end

      {:error, :not_found} ->
        %{
          template_state: "unavailable",
          template_name: template_name,
          managed: true,
          stored_digest_present: is_binary(stored_digest),
          digest_match: nil,
          source_layer: nil
        }

      _ ->
        %{
          template_state: "unavailable",
          template_name: template_name,
          managed: true,
          stored_digest_present: is_binary(stored_digest),
          digest_match: nil,
          source_layer: nil
        }
    end
  end

  defp gather_task_control(deps) do
    try do
      case deps.task_store.recovery_ready?() do
        true ->
          recovery_facts(true, true)

        false ->
          recovery_facts(false, true)

        _malformed ->
          recovery_facts(false, false)
      end
    rescue
      _ -> recovery_facts(false, false)
    catch
      _, _ -> recovery_facts(false, false)
    end
  end

  defp recovery_facts(recovery_ready?, recovery_facts_ok?) do
    %{
      recovery_ready?: recovery_ready?,
      recovery_facts_ok?: recovery_facts_ok?,
      required_grants: @required_grants
    }
  end

  defp gather_executor(deps, agent_id, task, caller_id, timeout) do
    config = deps.config
    callback_timeout_ms = resolve_callback_timeout(deps)

    kind_result =
      case task_kind(task, config) do
        {:ok, kind} -> {kind, config.task_executor(kind)}
        {:error, reason} -> {nil, {:error, reason}}
      end

    case kind_result do
      {nil, {:error, _reason}} ->
        %{
          kind: nil,
          callback_present?: false,
          projection: nil,
          diagnostic: %{
            "code" => "unsupported_or_missing_kind",
            "message" => "coding dispatch readiness requires a configured task kind"
          }
        }

      {kind, {:error, _reason}} ->
        %{
          kind: kind,
          callback_present?: false,
          projection: nil,
          diagnostic: %{
            "code" => "executor_unavailable",
            "message" => "configured task executor is unavailable"
          }
        }

      {kind, {:ok, module}} ->
        if function_exported?(module, :project_dispatch_readiness, 3) do
          context = readiness_context(caller_id, timeout)

          case deps.invoke_executor.(module, agent_id, task, context, callback_timeout_ms) do
            {:ok, report} ->
              # Core validates original JSON + closed status before any bounding.
              %{
                kind: kind,
                callback_present?: true,
                projection: report,
                diagnostic: nil
              }

            {:error, :executor_callback_timeout} ->
              %{
                kind: kind,
                callback_present?: true,
                projection: nil,
                diagnostic: %{
                  "code" => "executor_callback_timeout",
                  "message" => "executor readiness callback timed out"
                }
              }

            {:error, :executor_callback_exception} ->
              %{
                kind: kind,
                callback_present?: true,
                projection: nil,
                diagnostic: %{
                  "code" => "executor_callback_exception",
                  "message" => "executor readiness callback raised"
                }
              }

            {:error, :executor_callback_exit} ->
              %{
                kind: kind,
                callback_present?: true,
                projection: nil,
                diagnostic: %{
                  "code" => "executor_callback_exit",
                  "message" => "executor readiness callback exited"
                }
              }

            {:error, _} ->
              %{
                kind: kind,
                callback_present?: true,
                projection: nil,
                diagnostic: %{
                  "code" => "executor_projection_error",
                  "message" => "executor readiness returned an error"
                }
              }

            _other ->
              %{
                kind: kind,
                callback_present?: true,
                projection: nil,
                diagnostic: %{
                  "code" => "executor_malformed_return",
                  "message" => "executor readiness returned a malformed result"
                }
              }
          end
        else
          %{
            kind: kind,
            callback_present?: false,
            projection: nil,
            diagnostic: %{
              "code" => "executor_callback_missing",
              "message" => "configured executor does not implement project_dispatch_readiness/3"
            }
          }
        end
    end
  end

  defp resolve_callback_timeout(%{callback_timeout_ms: ms})
       when is_integer(ms) and ms > 0,
       do: ms

  defp resolve_callback_timeout(_), do: Config.executor_callback_timeout_ms()

  # Match TaskStore.call_executor_callback/3: supervised async_nolink, rescue
  # inside the task, bounded yield, brutal kill on hang. Never link the caller.
  defp default_invoke_executor(module, agent_id, task, context, timeout_ms) do
    supervisor = Arbor.Agent.Orchestration.TaskSupervisor

    task_ref =
      Task.Supervisor.async_nolink(supervisor, fn ->
        try do
          module.project_dispatch_readiness(agent_id, task, context)
        rescue
          _ -> {:error, :executor_callback_exception}
        catch
          :throw, _ -> {:error, :executor_callback_exception}
          :exit, _ -> {:error, :executor_callback_exit}
        end
      end)

    case Task.yield(task_ref, timeout_ms) || Task.shutdown(task_ref, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :executor_callback_timeout}
      {:exit, _} -> {:error, :executor_callback_exit}
    end
  rescue
    _ -> {:error, :executor_callback_failed}
  catch
    _, _ -> {:error, :executor_callback_failed}
  end

  defp readiness_context(caller_id, timeout) do
    base =
      if is_binary(caller_id) and caller_id != "" do
        %{"caller_id" => caller_id}
      else
        %{}
      end

    if is_integer(timeout) and timeout > 0 do
      Map.put(base, "timeout", timeout)
    else
      base
    end
  end

  # Use the injected Config collaborator on the test seam; production deps pin
  # Arbor.Agent.Config via production_deps/0.
  defp task_kind(task, config) when is_map(task) and is_atom(config) do
    kind = Map.get(task, "kind") || Map.get(task, :kind)
    config.normalize_kind(kind)
  end

  defp task_kind(_, _), do: {:error, :invalid_task_kind}

  defp require_exported(module, fun, arity) when is_atom(module) do
    if function_exported?(module, fun, arity) do
      :ok
    else
      {:error, :missing_readonly_collaborator}
    end
  end

  defp require_exported(_, _, _), do: {:error, :missing_readonly_collaborator}

  defp template_name(%{template: name}) when is_binary(name) and name != "", do: {:ok, name}

  defp template_name(%{template: name}) when is_atom(name) and not is_nil(name) do
    {:ok, Atom.to_string(name)}
  end

  defp template_name(_), do: {:error, :invalid_template_name}

  defp source_layer_from(data) when is_map(data) do
    case get_in(data, ["template_source", "layer"]) ||
           get_in(data, [:template_source, :layer]) do
      layer when layer in ["user", "shipped", "legacy_json"] -> layer
      _ -> nil
    end
  end

  defp source_layer_from(_), do: nil

  defp opt(opts, key) when is_list(opts) and is_atom(key), do: Keyword.get(opts, key)

  defp opt(opts, key) when is_map(opts) and is_atom(key) do
    case Map.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        # Only convert the known atom option key — never arbitrary map keys.
        Map.get(opts, Atom.to_string(key))
    end
  end

  defp opt(_, _), do: nil
end
