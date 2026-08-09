defmodule Arbor.Agent.Orchestration.DispatchReadinessCore do
  @moduledoc false

  # Pure CRC core for Agent-owned coding-dispatch readiness composition.
  # No process, store, filesystem, Security, or Config I/O.

  @version 1
  @kind "agent_coding_dispatch_readiness"
  @statuses ~w(ready degraded blocked error)
  @required_grants 6
  @max_message_bytes 256
  @max_string_bytes 1_024
  @max_key_bytes 256
  @max_top_string_bytes 512
  # Distinct structural limits: executor original envelope vs Agent aggregate.
  # Wrapper path is planes -> plane -> details -> projection (4 levels).
  @max_executor_depth 8
  @max_wrapper_overhead 4
  @max_aggregate_depth @max_executor_depth + @max_wrapper_overhead
  @max_list_len 32
  @max_map_keys 64

  @lease_roles [
    "task_read",
    "approval_read",
    "task_steer",
    "task_cancel",
    "task_adopt",
    "approval_answer"
  ]

  @plane_keys ~w(security coordinator exact_template task_control executor)
  @top_keys ~w(version kind status observed_at agent_id caller_id planes error)

  # Operational non-readiness remains blocked; internal projection failures are error.
  @blocked_executor_codes MapSet.new([
    "executor_callback_missing",
    "unsupported_or_missing_kind",
    "executor_unavailable"
  ])

  @type json_scalar :: String.t() | number() | boolean() | nil
  @type json_value :: json_scalar() | [json_value()] | %{optional(String.t()) => json_value()}
  @type report :: %{optional(String.t()) => json_value()}

  @spec lease_roles() :: [String.t()]
  def lease_roles, do: @lease_roles

  @spec required_grants() :: pos_integer()
  def required_grants, do: @required_grants

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec max_executor_depth() :: pos_integer()
  def max_executor_depth, do: @max_executor_depth

  @spec max_aggregate_depth() :: pos_integer()
  def max_aggregate_depth, do: @max_aggregate_depth

  @spec max_key_bytes() :: pos_integer()
  def max_key_bytes, do: @max_key_bytes

  @spec max_string_bytes() :: pos_integer()
  def max_string_bytes, do: @max_string_bytes

  @doc """
  Compose a full readiness report from already-projected plane facts.

  `facts` is a map with atom keys used only inside the pure core (never public):
  `:observed_at`, `:agent_id`, `:caller_id`, and plane maps under
  `:security`, `:coordinator`, `:exact_template`, `:task_control`, `:executor`.
  """
  @spec compose(map()) :: {:ok, report()} | {:error, :malformed_plane_input}
  def compose(facts) when is_map(facts) do
    with {:ok, security} <- normalize_plane(Map.get(facts, :security)),
         {:ok, coordinator} <- normalize_plane(Map.get(facts, :coordinator)),
         {:ok, exact_template} <- normalize_plane(Map.get(facts, :exact_template)),
         {:ok, task_control} <- normalize_plane(Map.get(facts, :task_control)),
         {:ok, executor} <- normalize_plane(Map.get(facts, :executor)) do
      planes = %{
        "security" => security,
        "coordinator" => coordinator,
        "exact_template" => exact_template,
        "task_control" => task_control,
        "executor" => executor
      }

      status = compose_status(planes)
      error = top_error(status, planes)

      report = %{
        "version" => @version,
        "kind" => @kind,
        "status" => status,
        "observed_at" => top_string_or_nil(Map.get(facts, :observed_at)),
        "agent_id" => top_string_or_nil(Map.get(facts, :agent_id)),
        "caller_id" => top_string_or_nil(Map.get(facts, :caller_id)),
        "planes" => planes,
        "error" => error
      }

      if aggregate_json_clean?(report) and closed_top?(report) do
        {:ok, report}
      else
        {:error, :malformed_plane_input}
      end
    else
      _ -> {:error, :malformed_plane_input}
    end
  end

  def compose(_), do: {:error, :malformed_plane_input}

  @doc "Build a top-level error report when the shell cannot project planes."
  @spec error_report(keyword() | map()) :: report()
  def error_report(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)
    code = stable_code(Map.get(attrs, :code, "projection_failed"))
    message = bound_message(Map.get(attrs, :message, "dispatch readiness failed closed"))

    planes =
      Enum.reduce(@plane_keys, %{}, fn key, acc ->
        Map.put(acc, key, plane("error", code, message, %{}))
      end)

    %{
      "version" => @version,
      "kind" => @kind,
      "status" => "error",
      "observed_at" => top_string_or_nil(Map.get(attrs, :observed_at)),
      "agent_id" => top_string_or_nil(Map.get(attrs, :agent_id)),
      "caller_id" => top_string_or_nil(Map.get(attrs, :caller_id)),
      "planes" => planes,
      "error" => %{"code" => code, "message" => message}
    }
  end

  @spec plane(String.t(), String.t() | nil, String.t() | nil, map()) :: map()
  def plane(status, code, message, details)
      when status in @statuses and is_map(details) do
    %{
      "status" => status,
      "code" => null_or_string(code),
      "message" => if(is_binary(message), do: bound_message(message), else: nil),
      "details" => bound_details(details)
    }
  end

  @doc """
  Project whether six sequential lease grants fit principal + global quotas.

  Principal occupancy must mirror CapabilityStore `by_principal` indexing:
  count includes expired-but-not-yet-removed entries. Callers obtain that
  count via `Security.list_capabilities(principal, include_expired: true)`
  and pass only the integer — never capability ids.

  Unavailable/malformed quota facts fail closed. Only an explicit
  `quota_enforcement_enabled?: false` bypasses limits.
  """
  @spec project_task_control(map()) :: map()
  def project_task_control(attrs) when is_map(attrs) do
    recovery_ready? = Map.get(attrs, :recovery_ready?) == true
    recovery_facts_ok? = Map.get(attrs, :recovery_facts_ok?, true) == true

    cond do
      not recovery_facts_ok? ->
        members = build_members(false, false, "recovery_projection_failed")

        plane("error", "recovery_projection_failed", "task-control recovery projection failed", %{
          "recovery_ready" => false,
          "members" => members,
          "quota" => %{
            "required_grants" => @required_grants,
            "principal_headroom" => nil,
            "global_headroom" => nil,
            "sufficient_for_lease" => false
          }
        })

      true ->
        case quota_decision(attrs) do
          {:ok, decision} ->
            members = build_members(recovery_ready?, decision.sufficient?, decision.member_code)

            status =
              cond do
                not recovery_ready? -> "blocked"
                not decision.sufficient? -> "blocked"
                true -> "ready"
              end

            code =
              cond do
                not recovery_ready? -> "recovery_not_ready"
                not decision.sufficient? -> decision.member_code
                true -> nil
              end

            message =
              cond do
                not recovery_ready? ->
                  "TaskStore recovery is not ready for control-lease minting"

                not decision.sufficient? ->
                  "insufficient capability quota headroom for six-member lease"

                true ->
                  nil
              end

            plane(status, code, message, %{
              "recovery_ready" => recovery_ready?,
              "members" => members,
              "quota" => %{
                "required_grants" => @required_grants,
                "principal_headroom" => decision.principal_headroom,
                "global_headroom" => decision.global_headroom,
                "sufficient_for_lease" => decision.sufficient?
              }
            })

          {:error, member_code, message} ->
            members = build_members(false, false, member_code)

            plane("blocked", member_code, message, %{
              "recovery_ready" => recovery_ready?,
              "members" => members,
              "quota" => %{
                "required_grants" => @required_grants,
                "principal_headroom" => nil,
                "global_headroom" => nil,
                "sufficient_for_lease" => false
              }
            })
        end
    end
  end

  @spec project_security(map()) :: map()
  def project_security(attrs) when is_map(attrs) do
    facts_ok? = Map.get(attrs, :facts_available?) == true
    healthy? = Map.get(attrs, :healthy?) == true
    restore_status = normalize_restore_status(Map.get(attrs, :restore_status))
    enforcement = Map.get(attrs, :quota_enforcement_enabled?)

    {status, code, message} =
      cond do
        not facts_ok? ->
          {"blocked", "security_facts_unavailable",
           "required security readiness facts are unavailable"}

        not healthy? ->
          {"blocked", "security_unhealthy", "security subsystem is not healthy"}

        restore_status == "failed" ->
          {"blocked", "security_restore_failed", "security capability restore is not ready"}

        restore_status == "unavailable" ->
          {"blocked", "security_restore_unavailable", "security capability restore is not ready"}

        enforcement not in [true, false] ->
          {"blocked", "security_quota_enforcement_unavailable",
           "security quota enforcement flag is unavailable"}

        true ->
          {"ready", nil, nil}
      end

    plane(status, code, message, %{
      "healthy" => facts_ok? and healthy?,
      "restore" => %{
        "status" => restore_status,
        "scanned" => required_non_neg(Map.get(attrs, :restore_scanned), 0),
        "active" => required_non_neg(Map.get(attrs, :restore_active), 0),
        "expired" => required_non_neg(Map.get(attrs, :restore_expired), 0),
        "superseded" => required_non_neg(Map.get(attrs, :restore_superseded), 0),
        "rejected" => required_non_neg(Map.get(attrs, :restore_rejected), 0)
      },
      "quota" => %{
        "enforcement_enabled" => if(enforcement in [true, false], do: enforcement, else: nil),
        "active_capabilities" => optional_non_neg(Map.get(attrs, :active_capabilities)),
        "max_global" => optional_positive(Map.get(attrs, :max_global)),
        "principal_active" => optional_non_neg(Map.get(attrs, :principal_indexed_count)),
        "max_per_principal" => optional_positive(Map.get(attrs, :max_per_principal))
      }
    })
  end

  @spec project_coordinator(map()) :: map()
  def project_coordinator(attrs) when is_map(attrs) do
    host_state =
      case Map.get(attrs, :host_state) do
        s when s in ["running", "absent", "not_alive", "error"] -> s
        _ -> "error"
      end

    {status, code, message} =
      case host_state do
        "running" ->
          {"ready", nil, nil}

        "not_alive" ->
          {"blocked", "coordinator_not_alive", "coordinator host process is not alive"}

        "absent" ->
          {"blocked", "coordinator_absent", "coordinator host is not running"}

        _ ->
          {"error", "coordinator_projection_failed", "coordinator host projection failed"}
      end

    plane(status, code, message, %{"host_state" => host_state})
  end

  @spec project_exact_template(map()) :: map()
  def project_exact_template(attrs) when is_map(attrs) do
    template_state =
      case Map.get(attrs, :template_state) do
        s when s in ["current", "drifted", "unavailable", "invalid", "unmanaged"] -> s
        _ -> "invalid"
      end

    source_layer =
      case Map.get(attrs, :source_layer) do
        s when s in ["user", "shipped", "legacy_json"] -> s
        _ -> nil
      end

    # Managed current requires closed source provenance; never report current without it.
    {template_state, source_layer} =
      if template_state == "current" and is_nil(source_layer) do
        {"invalid", nil}
      else
        {template_state, source_layer}
      end

    {status, code, message} =
      case template_state do
        "current" ->
          {"ready", nil, nil}

        "unmanaged" ->
          {"degraded", "exact_template_unmanaged",
           "profile is not marked with exact template policy"}

        "drifted" ->
          {"blocked", "exact_template_drifted", "managed exact template has drifted from source"}

        "unavailable" ->
          {"blocked", "exact_template_unavailable", "exact template source or profile unavailable"}

        "invalid" ->
          {"blocked", "exact_template_invalid", "exact template policy or source is invalid"}
      end

    plane(status, code, message, %{
      "template_state" => template_state,
      "template_name" => top_string_or_nil(Map.get(attrs, :template_name)),
      "managed" => Map.get(attrs, :managed) == true,
      "stored_digest_present" => Map.get(attrs, :stored_digest_present) == true,
      "digest_match" =>
        case Map.get(attrs, :digest_match) do
          true -> true
          false -> false
          _ -> nil
        end,
      "source_layer" => source_layer
    })
  end

  @doc """
  Project the configured-executor plane.

  The original callback report must already be valid string-keyed JSON with a
  closed status. Bounding runs only after validation and preserves status.
  """
  @spec project_executor(map()) :: map()
  def project_executor(attrs) when is_map(attrs) do
    callback_present? = Map.get(attrs, :callback_present?) == true
    kind = top_string_or_nil(Map.get(attrs, :kind))
    diagnostic = Map.get(attrs, :diagnostic)
    projection = Map.get(attrs, :projection)

    cond do
      not callback_present? ->
        diag = diagnostic_or(diagnostic, "executor_callback_missing")
        code = diag["code"]
        message = diag["message"]

        plane(
          "blocked",
          code,
          message,
          executor_details(kind, false, nil, diag)
        )

      match?(%{"code" => _, "message" => _}, diagnostic) and is_nil(projection) ->
        code = stable_code(diagnostic["code"])
        status = executor_diagnostic_status(code)

        plane(
          status,
          code,
          bound_message(diagnostic["message"]),
          executor_details(kind, true, nil, %{
            "code" => code,
            "message" => bound_message(diagnostic["message"])
          })
        )

      true ->
        case validate_and_bound_executor_report(projection) do
          {:ok, nested, nested_status} ->
            {status, code, message} =
              case nested_status do
                "ready" ->
                  {"ready", nil, nil}

                "degraded" ->
                  {"degraded", "executor_degraded",
                   "configured executor reports degraded readiness"}

                "blocked" ->
                  {"blocked", "executor_blocked", "configured executor reports blocked readiness"}

                "error" ->
                  {"error", "executor_error", "configured executor readiness projection failed"}
              end

            plane(
              status,
              code,
              message,
              executor_details(
                kind,
                true,
                nested,
                if(status == "ready", do: nil, else: %{"code" => code, "message" => message})
              )
            )

          {:error, err_code, err_message} ->
            plane(
              "error",
              err_code,
              err_message,
              executor_details(kind, true, nil, %{
                "code" => err_code,
                "message" => err_message
              })
            )
        end
    end
  end

  @doc """
  Validate an original executor report as string-keyed JSON with a closed status,
  then return a bounded copy that preserves the required status deterministically.
  """
  @spec validate_and_bound_executor_report(term()) ::
          {:ok, map(), String.t()} | {:error, String.t(), String.t()}
  def validate_and_bound_executor_report(report) do
    cond do
      not is_map(report) or is_struct(report) ->
        {:error, "executor_non_json", "executor readiness returned non-JSON data"}

      not executor_json_clean?(report) ->
        {:error, "executor_non_json", "executor readiness returned non-JSON data"}

      not Map.has_key?(report, "status") ->
        {:error, "executor_status_missing", "executor readiness is missing a status field"}

      report["status"] not in @statuses ->
        {:error, "executor_status_invalid", "executor readiness has an unknown status"}

      true ->
        case bound_json(report, @max_executor_depth) do
          {:ok, bounded} when is_map(bounded) ->
            # Preserve validated status even if nested truncation reshapes peers.
            bounded = Map.put(bounded, "status", report["status"])
            {:ok, bounded, report["status"]}

          _ ->
            {:error, "executor_non_json", "executor readiness returned non-JSON data"}
        end
    end
  end

  @doc "Recursively ensure value is string-keyed JSON-clean within aggregate bounds."
  @spec json_clean?(term()) :: boolean()
  def json_clean?(value), do: aggregate_json_clean?(value)

  @doc "Recursively ensure value is string-keyed JSON-clean within executor bounds."
  @spec executor_json_clean?(term()) :: boolean()
  def executor_json_clean?(value), do: do_json_clean?(value, 0, @max_executor_depth)

  @doc "Recursively ensure value is string-keyed JSON-clean within aggregate bounds."
  @spec aggregate_json_clean?(term()) :: boolean()
  def aggregate_json_clean?(value), do: do_json_clean?(value, 0, @max_aggregate_depth)

  @doc "Bound an already-validated JSON value. Rejects non-JSON inputs."
  @spec bound_json(term()) :: {:ok, json_value()} | {:error, :non_json}
  def bound_json(value), do: bound_json(value, @max_aggregate_depth)

  @spec bound_json(term(), pos_integer()) :: {:ok, json_value()} | {:error, :non_json}
  def bound_json(value, max_depth)
      when is_integer(max_depth) and max_depth > 0 do
    if do_json_clean?(value, 0, max_depth) do
      {:ok, do_bound(value, 0, max_depth)}
    else
      {:error, :non_json}
    end
  end

  def bound_json(_value, _max_depth), do: {:error, :non_json}

  @doc "Assert report is closed top-level JSON (for tests/facade)."
  @spec assert_report(term()) :: {:ok, report()} | {:error, :invalid_report}
  def assert_report(report) when is_map(report) do
    if aggregate_json_clean?(report) and closed_top?(report) and report["status"] in @statuses do
      {:ok, report}
    else
      {:error, :invalid_report}
    end
  end

  def assert_report(_), do: {:error, :invalid_report}

  @doc "UTF-8-safe string truncation to at most `max_bytes`."
  @spec utf8_truncate(String.t(), pos_integer()) :: String.t()
  def utf8_truncate(string, max_bytes)
      when is_binary(string) and is_integer(max_bytes) and max_bytes > 0 do
    cond do
      not String.valid?(string) ->
        ""

      byte_size(string) <= max_bytes ->
        string

      true ->
        do_utf8_truncate(string, max_bytes)
    end
  end

  # ---------------------------------------------------------------------------
  # Pure helpers
  # ---------------------------------------------------------------------------

  defp executor_diagnostic_status(code) when is_binary(code) do
    if MapSet.member?(@blocked_executor_codes, code), do: "blocked", else: "error"
  end

  defp executor_diagnostic_status(_), do: "error"

  defp quota_decision(attrs) do
    enforcement = Map.get(attrs, :quota_enforcement_enabled?)
    principal = Map.get(attrs, :principal_indexed_count)
    global = Map.get(attrs, :active_capabilities)
    max_per = Map.get(attrs, :max_per_principal)
    max_global = Map.get(attrs, :max_global)
    facts_ok? = Map.get(attrs, :facts_available?, true)

    cond do
      facts_ok? != true ->
        {:error, "quota_facts_unavailable", "required task-control quota facts are unavailable"}

      enforcement == false ->
        {:ok,
         %{
           sufficient?: true,
           principal_headroom: nil,
           global_headroom: nil,
           member_code: nil
         }}

      enforcement != true ->
        {:error, "quota_enforcement_unavailable",
         "security quota enforcement flag is unavailable"}

      not non_neg_int?(principal) ->
        {:error, "principal_quota_count_unavailable",
         "principal indexed capability count is unavailable"}

      not non_neg_int?(global) ->
        {:error, "global_quota_count_unavailable", "global active capability count is unavailable"}

      not positive_int?(max_per) or not positive_int?(max_global) ->
        {:error, "quota_limits_unavailable", "capability quota limits are unavailable"}

      true ->
        principal_headroom = max(max_per - principal, 0)
        global_headroom = max(max_global - global, 0)
        principal_ok? = principal + @required_grants <= max_per
        global_ok? = global + @required_grants <= max_global
        sufficient? = principal_ok? and global_ok?

        code =
          cond do
            not principal_ok? -> "quota_insufficient_principal"
            not global_ok? -> "quota_insufficient_global"
            true -> nil
          end

        {:ok,
         %{
           sufficient?: sufficient?,
           principal_headroom: principal_headroom,
           global_headroom: global_headroom,
           member_code: code
         }}
    end
  end

  defp build_members(recovery_ready?, sufficient?, member_code) do
    Map.new(@lease_roles, fn role ->
      provisionable? = recovery_ready? and sufficient?

      {role,
       %{
         "role" => role,
         "provisionable" => provisionable?,
         "code" =>
           cond do
             not recovery_ready? -> "recovery_not_ready"
             not provisionable? -> member_code
             true -> nil
           end
       }}
    end)
  end

  defp compose_status(planes) do
    statuses = Enum.map(@plane_keys, &get_in(planes, [&1, "status"]))

    cond do
      Enum.any?(statuses, &(&1 == "error")) -> "error"
      Enum.any?(statuses, &(&1 == "blocked")) -> "blocked"
      Enum.any?(statuses, &(&1 == "degraded")) -> "degraded"
      Enum.all?(statuses, &(&1 == "ready")) -> "ready"
      true -> "error"
    end
  end

  defp top_error("error", planes) do
    plane =
      Enum.find_value(@plane_keys, fn key ->
        p = planes[key]
        if p["status"] == "error", do: p
      end)

    %{
      "code" => stable_code((plane && plane["code"]) || "projection_failed"),
      "message" =>
        bound_message((plane && plane["message"]) || "dispatch readiness failed closed")
    }
  end

  defp top_error(_status, _planes), do: nil

  defp normalize_plane(
         %{
           "status" => status,
           "code" => code,
           "message" => message,
           "details" => details
         } = plane
       )
       when status in @statuses and is_map(details) and map_size(plane) == 4 do
    {:ok,
     %{
       "status" => status,
       "code" => null_or_string(code),
       "message" => if(is_binary(message), do: bound_message(message), else: nil),
       "details" => bound_details(details)
     }}
  end

  defp normalize_plane(_), do: :error

  defp executor_details(kind, callback_present?, projection, diagnostic) do
    %{
      "kind" => kind,
      "callback_present" => callback_present?,
      "projection" => projection,
      "diagnostic" => diagnostic
    }
  end

  defp diagnostic_or(%{"code" => c, "message" => m}, _default)
       when is_binary(c) and is_binary(m) do
    %{"code" => stable_code(c), "message" => bound_message(m)}
  end

  defp diagnostic_or(_other, default_code) do
    %{
      "code" => stable_code(default_code),
      "message" => bound_message("configured executor readiness is unavailable")
    }
  end

  defp closed_top?(report) do
    MapSet.new(Map.keys(report)) == MapSet.new(@top_keys) and
      is_map(report["planes"]) and
      MapSet.new(Map.keys(report["planes"])) == MapSet.new(@plane_keys)
  end

  # Structural JSON cleanliness. Size limits apply during bound_json/2;
  # excessive depth and overlong keys are structural failures (not truncated).
  defp do_json_clean?(nil, _depth, _max), do: true

  defp do_json_clean?(v, _depth, _max) when is_boolean(v) or is_integer(v) or is_float(v),
    do: true

  defp do_json_clean?(v, _depth, _max) when is_binary(v), do: String.valid?(v)

  defp do_json_clean?(list, depth, max_depth)
       when is_list(list) and depth < max_depth do
    Enum.all?(list, &do_json_clean?(&1, depth + 1, max_depth))
  end

  defp do_json_clean?(list, depth, max_depth)
       when is_list(list) and depth >= max_depth,
       do: false

  defp do_json_clean?(map, depth, max_depth)
       when is_map(map) and not is_struct(map) and depth < max_depth do
    Enum.all?(map, fn
      {k, v} when is_binary(k) ->
        String.valid?(k) and byte_size(k) <= @max_key_bytes and
          do_json_clean?(v, depth + 1, max_depth)

      _ ->
        false
    end)
  end

  defp do_json_clean?(map, depth, max_depth)
       when is_map(map) and not is_struct(map) and depth >= max_depth,
       do: false

  defp do_json_clean?(_, _, _), do: false

  # Bound only after json_clean? validation. Deterministic map key order.
  # Overlong keys are never accepted (rejected above); values may truncate.
  defp do_bound(nil, _depth, _max), do: nil
  defp do_bound(v, _depth, _max) when is_boolean(v) or is_integer(v) or is_float(v), do: v

  defp do_bound(v, _depth, _max) when is_binary(v), do: utf8_truncate(v, @max_string_bytes)

  defp do_bound(list, depth, max_depth) when is_list(list) and depth < max_depth do
    list
    |> Enum.take(@max_list_len)
    |> Enum.map(&do_bound(&1, depth + 1, max_depth))
  end

  defp do_bound(map, depth, max_depth)
       when is_map(map) and not is_struct(map) and depth < max_depth do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.filter(fn {k, _} -> is_binary(k) and byte_size(k) <= @max_key_bytes end)
    |> Enum.take(@max_map_keys)
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      Map.put(acc, k, do_bound(v, depth + 1, max_depth))
    end)
  end

  defp do_bound(_, _, _), do: nil

  defp bound_details(map) when is_map(map) do
    case stringify_supported_keys(map) do
      {:ok, string_keyed} ->
        case bound_json(string_keyed, @max_aggregate_depth) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      :error ->
        %{}
    end
  end

  # Plane construction may use atom keys internally; only convert atoms.
  # Never call to_string/1 on arbitrary keys (tuple/struct/pid raise or launder).
  defp stringify_supported_keys(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {k, v}, {:ok, acc} when is_atom(k) ->
        case stringify_supported_keys(v) do
          {:ok, sv} -> {:cont, {:ok, Map.put(acc, Atom.to_string(k), sv)}}
          :error -> {:halt, :error}
        end

      {k, v}, {:ok, acc} when is_binary(k) ->
        if String.valid?(k) and byte_size(k) <= @max_key_bytes do
          case stringify_supported_keys(v) do
            {:ok, sv} -> {:cont, {:ok, Map.put(acc, k, sv)}}
            :error -> {:halt, :error}
          end
        else
          {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp stringify_supported_keys(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case stringify_supported_keys(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp stringify_supported_keys(v)
       when is_binary(v) or is_boolean(v) or is_integer(v) or is_float(v) or is_nil(v) do
    if is_binary(v) and not String.valid?(v), do: :error, else: {:ok, v}
  end

  defp stringify_supported_keys(_), do: :error

  defp bound_message(message) when is_binary(message),
    do: utf8_truncate(message, @max_message_bytes)

  defp bound_message(_), do: "dispatch readiness failed closed"

  defp do_utf8_truncate(string, max_bytes) do
    string
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, size} ->
      gsize = byte_size(grapheme)

      if size + gsize <= max_bytes do
        {:cont, {acc <> grapheme, size + gsize}}
      else
        {:halt, {acc, size}}
      end
    end)
    |> elem(0)
  end

  defp stable_code(code) when is_atom(code), do: Atom.to_string(code)

  defp stable_code(code) when is_binary(code) do
    code
    |> utf8_truncate(64)
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> case do
      "" -> "projection_failed"
      c -> c
    end
  end

  defp stable_code(_), do: "projection_failed"

  defp top_string_or_nil(v) when is_binary(v) and v != "" do
    if String.valid?(v), do: utf8_truncate(v, @max_top_string_bytes), else: nil
  end

  defp top_string_or_nil(_), do: nil

  defp null_or_string(nil), do: nil
  defp null_or_string(v) when is_binary(v), do: utf8_truncate(v, 64)
  defp null_or_string(v) when is_atom(v), do: Atom.to_string(v)
  defp null_or_string(_), do: nil

  defp normalize_restore_status(status) when status in ["ready", "failed", "unavailable"],
    do: status

  defp normalize_restore_status(_), do: "unavailable"

  defp required_non_neg(v, _default) when is_integer(v) and v >= 0, do: v
  defp required_non_neg(_, default), do: default

  defp optional_non_neg(v) when is_integer(v) and v >= 0, do: v
  defp optional_non_neg(_), do: nil

  defp optional_positive(v) when is_integer(v) and v > 0, do: v
  defp optional_positive(_), do: nil

  defp non_neg_int?(v) when is_integer(v) and v >= 0, do: true
  defp non_neg_int?(_), do: false

  defp positive_int?(v) when is_integer(v) and v > 0, do: true
  defp positive_int?(_), do: false
end
