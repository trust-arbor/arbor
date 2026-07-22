defmodule Arbor.Orchestrator.CodingPlan.Readiness do
  @moduledoc false

  alias Arbor.Contracts.Coding.Plan

  alias Arbor.Orchestrator.CodingPlan.{
    Compilation,
    Normalizer,
    ReadinessCore,
    ReadinessLiveCore,
    WorkspaceScope
  }

  alias Arbor.Orchestrator.Config

  @compiler_options [:template_path, :template_source, :action_catalog]
  @doc false
  @spec prepare(term(), keyword()) ::
          {:ok, Plan.t(), Compilation.t()} | {:error, term()}
  def prepare(plan_or_attrs, opts \\ [])

  def prepare(plan_or_attrs, opts) when is_list(opts) do
    with {:ok, plan} <- normalize_plan(plan_or_attrs),
         {:ok, repo_roots} <- configured_roots(opts, :repo),
         {:ok, worktree_roots} <- configured_roots(opts, :worktree),
         {:ok, canonical_plan} <- WorkspaceScope.normalize(plan, repo_roots, worktree_roots),
         {:ok, compilation} <- compile(canonical_plan, opts),
         {:ok, validated} <- Compilation.validate(compilation, canonical_plan) do
      {:ok, canonical_plan, validated}
    end
  end

  def prepare(_plan_or_attrs, _opts), do: {:error, :invalid_options}

  @doc false
  @spec check(term(), keyword()) :: {:ok, map()}
  def check(plan_or_attrs, opts) when is_list(opts) do
    observed_at = Keyword.get(opts, :observed_at)
    plan_digest = invalid_plan_digest()

    case normalize_observation_time(observed_at) do
      {:ok, observed_at} ->
        case Keyword.get(opts, :mode, :static) do
          mode when mode in [:static, :live] ->
            check_with_time(plan_or_attrs, opts, observed_at, plan_digest, mode)

          _unknown_mode ->
            ReadinessCore.report(
              plan_digest,
              observed_at,
              [
                blocked(
                  "readiness_mode",
                  "mode_invalid",
                  observed_at,
                  "The readiness observation mode is invalid.",
                  "Use the supported static or live readiness mode."
                )
              ]
            )
        end

      {:error, _reason} ->
        ReadinessCore.report(
          plan_digest,
          fallback_observed_at(observed_at),
          [
            blocked(
              "plan_schema",
              "invalid_observation_time",
              fallback_observed_at(observed_at),
              "The readiness observation time is invalid.",
              "Provide an ISO-8601 UTC observation timestamp."
            )
          ]
        )
    end
  end

  def check(plan_or_attrs, _opts), do: check(plan_or_attrs, [])

  @doc false
  @spec check_prepared(Plan.t(), Compilation.t(), keyword()) :: {:ok, map()}
  def check_prepared(%Plan{} = plan, %Compilation{} = compilation, opts) when is_list(opts) do
    observed_at = Keyword.get(opts, :observed_at)
    plan_digest = ReadinessCore.plan_digest(Plan.to_map(plan))

    case normalize_observation_time(observed_at) do
      {:ok, observed_at} ->
        case Keyword.get(opts, :mode, :static) do
          mode when mode in [:static, :live] ->
            check_prepared_with_time(plan, compilation, opts, observed_at, plan_digest, mode)

          _unknown_mode ->
            ReadinessCore.report(
              plan_digest,
              observed_at,
              [
                blocked(
                  "readiness_mode",
                  "mode_invalid",
                  observed_at,
                  "The readiness observation mode is invalid.",
                  "Use the supported static or live readiness mode."
                )
              ]
            )
        end

      {:error, _reason} ->
        ReadinessCore.report(
          plan_digest,
          fallback_observed_at(observed_at),
          [
            blocked(
              "plan_schema",
              "invalid_observation_time",
              fallback_observed_at(observed_at),
              "The readiness observation time is invalid.",
              "Provide an ISO-8601 UTC observation timestamp."
            )
          ]
        )
    end
  end

  def check_prepared(_plan, _compilation, _opts),
    do:
      ReadinessCore.report(
        invalid_plan_digest(),
        "1970-01-01T00:00:00.000Z",
        [
          blocked(
            "provenance",
            "prepared_compilation_invalid",
            "1970-01-01T00:00:00.000Z",
            "The prepared coding compilation is invalid.",
            "Provide the exact validated compilation for the canonical plan."
          )
        ]
      )

  defp check_with_time(plan_or_attrs, opts, observed_at, invalid_digest, mode) do
    case normalize_plan(plan_or_attrs) do
      {:ok, plan} ->
        requested_plan_digest = ReadinessCore.plan_digest(Plan.to_map(plan))
        check_plan(plan, requested_plan_digest, opts, observed_at, mode)

      {:error, reason} ->
        ReadinessCore.report(
          invalid_digest,
          observed_at,
          [
            blocked(
              "plan_schema",
              plan_error_code(reason),
              observed_at,
              "The coding plan does not satisfy the versioned plan contract.",
              "Provide a valid version 1 plan with a task, repo_root, and worker provider."
            )
          ]
        )
    end
  end

  defp check_plan(plan, requested_plan_digest, opts, observed_at, mode) do
    with {:ok, canonical_plan, compilation} <- prepare(plan, opts) do
      check_prepared_with_time(
        canonical_plan,
        compilation,
        opts,
        observed_at,
        ReadinessCore.plan_digest(Plan.to_map(canonical_plan)),
        mode
      )
    else
      {:error, reason} ->
        blocked_report(requested_plan_digest, observed_at, reason)
    end
  end

  defp check_prepared_with_time(plan, compilation, opts, observed_at, plan_digest, mode) do
    case Compilation.validate(compilation, plan) do
      {:ok, ^compilation} ->
        base_diagnostics = immutable_diagnostics(observed_at)

        case mode do
          :static ->
            ReadinessCore.report(
              plan_digest,
              observed_at,
              base_diagnostics ++ static_dynamic_diagnostics(observed_at)
            )

          :live ->
            live_report(plan_digest, plan, opts, observed_at, base_diagnostics)
        end

      {:error, reason} ->
        blocked_report(plan_digest, observed_at, {:prepared_compilation_invalid, reason})
    end
  end

  defp immutable_diagnostics(observed_at) do
    [
      passed("plan_schema", "plan_valid", observed_at, "The coding plan is valid."),
      passed(
        "trusted_roots",
        "roots_valid",
        observed_at,
        "Trusted repo and worktree roots are valid."
      ),
      passed(
        "compiler",
        "compilation_valid",
        observed_at,
        "The reviewed plan compiled successfully."
      ),
      passed(
        "provenance",
        "provenance_valid",
        observed_at,
        "Compilation provenance is internally consistent."
      )
    ]
  end

  defp live_report(plan_digest, plan, opts, observed_at, base_diagnostics) do
    observed_datetime = parse_datetime!(observed_at)
    {:ok, expires_at} = ReadinessLiveCore.expiry(observed_datetime, nil)

    case live_diagnostics(plan, opts, observed_at, observed_datetime, expires_at) do
      {:ok, diagnostics, expires_at} ->
        ReadinessCore.report(
          plan_digest,
          observed_at,
          base_diagnostics ++ diagnostics,
          expires_at: iso_datetime(expires_at)
        )

      {:blocked, diagnostic, expires_at} ->
        ReadinessCore.report(
          plan_digest,
          observed_at,
          base_diagnostics ++ [diagnostic],
          expires_at: iso_datetime(expires_at)
        )
    end
  end

  defp live_diagnostics(plan, opts, observed_at, observed_datetime, expires_at) do
    with {:ok, security_diagnostic} <- observe_security(opts, observed_at),
         {:ok, acp_diagnostic, provider_expiry} <-
           observe_acp(plan, opts, observed_at, observed_datetime),
         {:ok, toolchain_diagnostic} <- observe_toolchain(opts, observed_at),
         {:ok, capacity_diagnostic} <- observe_capacity(opts, observed_at) do
      {:ok, [security_diagnostic, acp_diagnostic, toolchain_diagnostic, capacity_diagnostic],
       earlier_expiry(expires_at, provider_expiry)}
    else
      {:blocked, diagnostic} -> {:blocked, diagnostic, expires_at}
    end
  end

  defp observe_security(opts, observed_at) do
    agent_id = Keyword.get(opts, :agent_id)

    cond do
      not valid_agent_id?(agent_id) ->
        {:blocked,
         blocked(
           "security_authority",
           "agent_id_invalid",
           observed_at,
           "The live readiness agent identity is invalid.",
           "Provide a non-empty agent identity in the agent_ namespace."
         )}

      safe_observer(:security_available?, [], &Config.security_available?/0) != {:ok, true} ->
        {:blocked,
         blocked(
           "security_authority",
           "security_authority_unavailable",
           observed_at,
           "The live security authority is unavailable.",
           "Restore the security authority before dispatch."
         )}

      safe_observer(
        :signing_key_status,
        [agent_id],
        fn value ->
          apply(Config.coding_readiness_security_module(), :signing_key_status, [value])
        end
      ) != {:ok, {:ok, :available}} ->
        {:blocked,
         blocked(
           "security_authority",
           "signing_key_unavailable",
           observed_at,
           "The live agent signing key is unavailable.",
           "Restore the agent signing key before dispatch."
         )}

      true ->
        {:ok,
         passed(
           "security_authority",
           "security_authority_available",
           observed_at,
           "The live security authority and agent signing key are available."
         )}
    end
  end

  defp observe_acp(plan, _opts, observed_at, observed_datetime) do
    provider = plan.worker["provider"]
    requested_model = plan.worker["model"]

    result =
      safe_observer(
        :acp_provider_readiness,
        [provider, requested_model],
        fn provider_value, model_value ->
          apply(
            Config.coding_readiness_acp_module(),
            :acp_provider_readiness,
            [provider_value, model_value]
          )
        end
      )

    case result do
      {:ok, envelope} ->
        case ReadinessLiveCore.acp(envelope, provider, requested_model, observed_datetime) do
          {:ok, :passed, digest, provider_expiry} ->
            {:ok,
             passed_with_evidence(
               "acp_health",
               "acp_health_available",
               observed_at,
               "The ACP provider and requested model are available.",
               digest
             ), provider_expiry}

          {:ok, :degraded, digest, provider_expiry} ->
            {:ok,
             degraded_with_evidence(
               "acp_health",
               "acp_health_degraded",
               observed_at,
               "ACP provider evidence is degraded and authentication remains unconfirmed.",
               digest
             ), provider_expiry}

          {:error, :model_mismatch} ->
            {:blocked,
             blocked(
               "acp_health",
               "acp_model_mismatch",
               observed_at,
               "The ACP provider model does not match the coding plan.",
               "Use the provider model bound to the reviewed coding plan."
             )}

          {:error, :missing_executable} ->
            {:blocked,
             blocked(
               "acp_health",
               "acp_executable_unavailable",
               observed_at,
               "The ACP provider executable is unavailable.",
               "Restore the reviewed ACP provider executable before dispatch."
             )}

          {:error, :unavailable} ->
            {:blocked,
             blocked(
               "acp_health",
               "acp_unavailable",
               observed_at,
               "The ACP provider is unavailable for the coding plan.",
               "Restore provider availability and retry live readiness."
             )}

          {:error, :expired} ->
            {:blocked,
             blocked(
               "acp_health",
               "acp_evidence_expired",
               observed_at,
               "The ACP readiness evidence has expired.",
               "Refresh ACP readiness evidence before dispatch."
             )}

          {:error, :future} ->
            {:blocked,
             blocked(
               "acp_health",
               "acp_evidence_future",
               observed_at,
               "The ACP readiness evidence is dated in the future.",
               "Use an ACP observation at or before the readiness observation time."
             )}

          {:error, :malformed} ->
            {:blocked,
             blocked(
               "acp_health",
               "acp_evidence_invalid",
               observed_at,
               "The ACP readiness evidence is malformed.",
               "Return a canonical provider observation and matching digest."
             )}
        end

      _ ->
        {:blocked,
         blocked(
           "acp_health",
           "acp_evidence_invalid",
           observed_at,
           "The ACP readiness observation is unavailable.",
           "Restore the ACP readiness observer and retry live readiness."
         )}
    end
  end

  defp observe_toolchain(_opts, observed_at) do
    case safe_observer(
           :coding_toolchain_identity,
           [],
           fn ->
             apply(Config.coding_readiness_actions_module(), :coding_toolchain_identity, [])
           end
         ) do
      {:ok, {:ok, identity}} ->
        case ReadinessLiveCore.toolchain(identity) do
          {:ok, evidence_ref} ->
            {:ok,
             passed_with_evidence(
               "toolchain_identity",
               "toolchain_identity_available",
               observed_at,
               "The reviewed Mix and runtime toolchain identity is available.",
               evidence_ref
             )}

          {:error, :malformed} ->
            {:blocked,
             blocked(
               "toolchain_identity",
               "toolchain_identity_invalid",
               observed_at,
               "The toolchain identity evidence is malformed.",
               "Return the bounded reviewed toolchain identity."
             )}
        end

      _ ->
        {:blocked,
         blocked(
           "toolchain_identity",
           "toolchain_identity_unavailable",
           observed_at,
           "The coding toolchain identity is unavailable.",
           "Restore the reviewed Mix and runtime toolchain before dispatch."
         )}
    end
  end

  defp observe_capacity(_opts, observed_at) do
    case safe_observer(:validation_capacity_observer, [], fn -> :unavailable end) do
      {:ok, :available} ->
        {:ok,
         passed(
           "validation_capacity",
           "validation_capacity_available",
           observed_at,
           "Validation capacity is available."
         )}

      {:ok, :degraded} ->
        {:ok,
         unavailable(
           "validation_capacity",
           "validation_capacity_degraded",
           observed_at,
           "Validation capacity evidence is degraded.",
           "Confirm validation capacity before dispatch."
         )}

      _ ->
        {:ok,
         unavailable(
           "validation_capacity",
           "validation_capacity_unavailable",
           observed_at,
           "No authoritative validation capacity observer is available.",
           "Confirm validation capacity before dispatch."
         )}
    end
  end

  defp safe_observer(key, args, default) do
    observer =
      case Config.coding_readiness_observer_module() do
        module when is_atom(module) ->
          if Code.ensure_loaded?(module) and function_exported?(module, key, length(args)),
            do: {:module, module},
            else: {:function, default}

        _ ->
          {:function, default}
      end

    try do
      case observer do
        {:module, module} ->
          {:ok, apply(module, key, args)}

        {:function, function} when is_function(function, length(args)) ->
          {:ok, apply(function, args)}

        _ ->
          {:error, :observer_invalid}
      end
    rescue
      _ -> {:error, :observer_failed}
    catch
      _, _ -> {:error, :observer_failed}
    end
  end

  defp valid_agent_id?(agent_id) when is_binary(agent_id) and byte_size(agent_id) <= 256 do
    byte_size(agent_id) > 6 and String.valid?(agent_id) and
      not String.contains?(agent_id, <<0>>) and String.starts_with?(agent_id, "agent_")
  end

  defp valid_agent_id?(_agent_id), do: false

  defp earlier_expiry(first, second) do
    if DateTime.compare(first, second) == :lt, do: first, else: second
  end

  defp parse_datetime!(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp iso_datetime(datetime), do: DateTime.to_iso8601(datetime, :extended)

  defp passed_with_evidence(gate_id, code, observed_at, message, evidence_ref),
    do:
      ReadinessCore.diagnostic(
        gate_id,
        "preflight",
        "passed",
        code,
        observed_at,
        message,
        evidence_ref
      )

  defp degraded_with_evidence(gate_id, code, observed_at, message, evidence_ref),
    do:
      ReadinessCore.diagnostic(
        gate_id,
        "preflight",
        "degraded",
        code,
        observed_at,
        message,
        evidence_ref
      )

  defp configured_roots(opts, :repo) do
    case Keyword.fetch(opts, :repo_roots) do
      {:ok, roots} -> {:ok, roots}
      :error -> Config.coding_repo_roots()
    end
  end

  defp configured_roots(opts, :worktree) do
    case Keyword.fetch(opts, :worktree_roots) do
      {:ok, roots} -> {:ok, roots}
      :error -> Config.coding_worktree_roots()
    end
  end

  defp compile(plan, opts) do
    compiler_opts = Keyword.take(opts, @compiler_options)
    compiler = Config.coding_plan_compiler()

    if is_atom(compiler) and Code.ensure_loaded?(compiler) and
         function_exported?(compiler, :compile, 2) do
      try do
        compiler.compile(plan, compiler_opts)
      rescue
        _exception -> {:error, {:coding_plan_compiler_failed, :raise}}
      catch
        :exit, _reason -> {:error, {:coding_plan_compiler_failed, :exit}}
        :throw, _reason -> {:error, {:coding_plan_compiler_failed, :throw}}
      end
    else
      {:error, {:coding_plan_compiler_unavailable, compiler}}
    end
  end

  defp blocked_report(plan_digest, observed_at, reason) do
    {gate_id, code, message, remediation} = failure_diagnostic(reason)

    ReadinessCore.report(
      plan_digest,
      observed_at,
      [blocked(gate_id, code, observed_at, message, remediation)]
    )
  end

  defp failure_diagnostic({:coding_roots_not_configured, :repo}) do
    {"trusted_roots", "repo_roots_unconfigured", "Trusted repository roots are not configured.",
     "Configure at least one existing canonical repository root."}
  end

  defp failure_diagnostic({:coding_roots_not_configured, :worktree}) do
    {"trusted_roots", "worktree_roots_unconfigured", "Trusted worktree roots are not configured.",
     "Configure at least one existing canonical worktree root."}
  end

  defp failure_diagnostic({:invalid_coding_roots, kind}) do
    {"trusted_roots", "#{kind}_roots_invalid", "Configured #{kind} roots are invalid.",
     "Use existing absolute directories outside the filesystem root."}
  end

  defp failure_diagnostic({:invalid_coding_root, kind}) do
    {"trusted_roots", "#{kind}_root_invalid", "A configured #{kind} root is invalid.",
     "Use an existing absolute directory outside the filesystem root."}
  end

  defp failure_diagnostic({:error, reason}), do: failure_diagnostic(reason)

  defp failure_diagnostic(:invalid_repo_roots),
    do: root_failure("repo_roots_invalid", "repository")

  defp failure_diagnostic(:invalid_worktree_roots),
    do: root_failure("worktree_roots_invalid", "worktree")

  defp failure_diagnostic({:invalid_coding_path, :repo_path}),
    do: root_failure("repo_path_invalid", "repository")

  defp failure_diagnostic({:coding_path_outside_roots, :repo_path}),
    do: root_failure("repo_outside_root", "repository")

  defp failure_diagnostic(:git_root_outside_coding_roots),
    do: root_failure("git_root_outside_root", "Git repository")

  defp failure_diagnostic(:invalid_git_repository) do
    {"trusted_roots", "invalid_git_repository", "The requested path is not a Git repository.",
     "Use an existing path inside a trusted Git repository."}
  end

  defp failure_diagnostic({:invalid_coding_path, :worktree_base_dir}),
    do: root_failure("worktree_path_invalid", "worktree")

  defp failure_diagnostic({:coding_path_outside_roots, :worktree_base_dir}),
    do: root_failure("worktree_outside_root", "worktree")

  defp failure_diagnostic({:profile_not_executable, _id, _reason}) do
    {"executable_profile", "profile_not_executable",
     "The selected validation profile is not executable.",
     "Select a reviewed executable validation profile."}
  end

  defp failure_diagnostic({:unknown_profile, _id}) do
    {"executable_profile", "profile_unknown", "The selected validation profile is unknown.",
     "Select a known reviewed validation profile."}
  end

  defp failure_diagnostic({:action_catalog_failed, _reason}) do
    {"action_catalog", "action_catalog_invalid", "The action catalog could not be validated.",
     "Refresh the reviewed action catalog and retry the readiness check."}
  end

  defp failure_diagnostic({:invalid_action_catalog, _reason}) do
    failure_diagnostic({:action_catalog_failed, :invalid})
  end

  defp failure_diagnostic({:unknown_handler_types, _handlers}) do
    {"handler_catalog", "handler_type_unknown",
     "The compiled plan references an unknown handler type.",
     "Use only reviewed handler types in the coding template."}
  end

  defp failure_diagnostic({:unknown_action, _node_id, _action}) do
    {"action_catalog", "action_unknown", "The compiled plan references an unknown action.",
     "Use only reviewed actions present in the action catalog."}
  end

  defp failure_diagnostic({:invalid_action_node, _node_id, _reason}) do
    {"action_catalog", "action_node_invalid", "A compiled action node is invalid.",
     "Use the reviewed action-node shape from the coding template."}
  end

  defp failure_diagnostic({:semantic_preflight_failed, _errors}) do
    {"semantic_preflight", "semantic_preflight_failed",
     "Semantic preflight rejected the compiled plan.",
     "Correct the reviewed template or plan policy inputs and rerun readiness."}
  end

  defp failure_diagnostic({:missing_requirements, _missing}) do
    {"executable_profile", "profile_requirements_missing",
     "The plan does not satisfy profile requirements.",
     "Select a compatible profile or restore its required graph capabilities."}
  end

  defp failure_diagnostic({:missing_nested_actions, _actions}) do
    {"action_catalog", "nested_action_missing",
     "A reviewed nested action is missing from the catalog.",
     "Refresh the action catalog with all reviewed nested actions."}
  end

  defp failure_diagnostic({:invalid_manifest, _reason}) do
    provenance_failure("execution_manifest_invalid")
  end

  defp failure_diagnostic({:coding_plan_compiler_error, tag}), do: compiler_failure(tag)
  defp failure_diagnostic({:coding_plan_compiler_failed, tag}), do: compiler_failure(tag)

  defp failure_diagnostic({:coding_plan_template_unavailable, _path, _reason}),
    do: compiler_failure(:template)

  defp failure_diagnostic({:coding_plan_compiler_unavailable, _compiler}),
    do: compiler_failure(:compiler)

  defp failure_diagnostic({:template_read_failed, _reason}), do: compiler_failure(:template)
  defp failure_diagnostic({:template_parse_failed, _reason}), do: compiler_failure(:template)
  defp failure_diagnostic({:generated_dot_parse_failed, _reason}), do: compiler_failure(:template)

  defp failure_diagnostic({:compilation_field_mismatch, _field}),
    do: provenance_failure("provenance_mismatch")

  defp failure_diagnostic({:invalid_compilation_field, _field}),
    do: provenance_failure("compilation_invalid")

  defp failure_diagnostic({:prepared_compilation_invalid, _reason}),
    do: provenance_failure("prepared_compilation_invalid")

  defp failure_diagnostic({:forbidden_compilation_key, _scope, _key}),
    do: provenance_failure("provenance_forbidden")

  defp failure_diagnostic(_reason), do: compiler_failure(:unknown)

  defp compiler_failure(:semantic_preflight_failed),
    do: failure_diagnostic({:semantic_preflight_failed, []})

  defp compiler_failure(:action_catalog_failed),
    do: failure_diagnostic({:action_catalog_failed, :unknown})

  defp compiler_failure(:template),
    do:
      {"compiler", "template_unavailable", "The reviewed coding template is unavailable.",
       "Restore the configured reviewed template and retry readiness."}

  defp compiler_failure(:compiler),
    do:
      {"compiler", "compiler_unavailable", "The reviewed coding-plan compiler is unavailable.",
       "Restore the configured coding-plan compiler and retry readiness."}

  defp compiler_failure(_tag),
    do:
      {"compiler", "compilation_failed", "The reviewed coding plan could not be compiled.",
       "Correct the reviewed compiler or template inputs and retry readiness."}

  defp provenance_failure(code),
    do:
      {"provenance", code, "Compilation provenance could not be verified.",
       "Regenerate the reviewed compilation and retry readiness."}

  defp root_failure(code, kind),
    do:
      {"trusted_roots", code, "The requested #{kind} path is not admitted by trusted roots.",
       "Use an existing path inside a configured canonical #{kind} root."}

  defp static_dynamic_diagnostics(observed_at) do
    [
      unavailable(
        "security_authority",
        "security_authority_unavailable",
        observed_at,
        "Live security authority was not observed in static mode.",
        "Run the live readiness check before dispatch."
      ),
      unavailable(
        "acp_health",
        "acp_health_unavailable",
        observed_at,
        "ACP provider and model health was not observed in static mode.",
        "Run the live readiness check before dispatch."
      ),
      unavailable(
        "toolchain_identity",
        "toolchain_identity_unavailable",
        observed_at,
        "Toolchain identity was not observed in static mode.",
        "Run live toolchain verification before dispatch."
      ),
      unavailable(
        "validation_capacity",
        "validation_capacity_unavailable",
        observed_at,
        "Validation capacity was not observed in static mode.",
        "Run live capacity verification before dispatch."
      )
    ]
  end

  defp passed(gate_id, code, observed_at, message),
    do: ReadinessCore.diagnostic(gate_id, "preflight", "passed", code, observed_at, message, nil)

  defp unavailable(gate_id, code, observed_at, message, remediation),
    do:
      ReadinessCore.diagnostic(
        gate_id,
        "preflight",
        "unavailable",
        code,
        observed_at,
        message,
        remediation
      )

  defp blocked(gate_id, code, observed_at, message, remediation),
    do:
      ReadinessCore.diagnostic(
        gate_id,
        "preflight",
        "blocked",
        code,
        observed_at,
        message,
        remediation
      )

  defp normalize_plan(%Plan{} = plan), do: {:ok, plan}

  defp normalize_plan(%{"kind" => _kind} = task), do: Normalizer.normalize_task(task)
  defp normalize_plan(%{"plan" => _plan} = task), do: Normalizer.normalize_task(task)
  defp normalize_plan(attrs), do: Plan.new(attrs)

  defp normalize_observation_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime, :extended)}
      _ -> {:error, :invalid_observation_time}
    end
  end

  defp normalize_observation_time(%DateTime{} = value),
    do: {:ok, DateTime.to_iso8601(value, :extended)}

  defp normalize_observation_time(_value), do: {:error, :invalid_observation_time}

  defp fallback_observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime, :extended)
      _ -> "1970-01-01T00:00:00.000Z"
    end
  end

  defp fallback_observed_at(_value), do: "1970-01-01T00:00:00.000Z"

  defp invalid_plan_digest, do: "sha256:" <> String.duplicate("0", 64)

  defp plan_error_code({:invalid_field, "validation_profile", _}), do: "profile_invalid"
  defp plan_error_code({:invalid_field, "task_class", _}), do: "profile_invalid"
  defp plan_error_code(_reason), do: "plan_invalid"
end
