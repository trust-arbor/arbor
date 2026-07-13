defmodule Arbor.Orchestrator.CodingPlan.Profiles do
  @moduledoc """
  Deterministic registry of reviewed coding-plan profiles.

  A declared profile is not necessarily executable. Call `fetch_executable/1`
  at execution boundaries so profiles whose enforcement contracts have not
  landed fail closed instead of falling back to `default`.
  """

  alias Arbor.Orchestrator.Graph

  @template_version "coding-change-v1"

  @default_required_nodes Enum.sort(~w[
                    acquire_workspace
                    check_operator_rework_category_budget
                    check_operator_rework_total_budget
                    check_review_category_budget
                    check_review_total_budget
                    check_validation_category_budget
                    check_validation_passed
                    check_validation_total_budget
                    close_worker
                    close_stale_worker
                    commit_change
                    check_recovery_provider_id
                    check_worker_send_recovery_budget
                    check_worker_status_session_id
                    coding_workspace_recovery_summary
                    done
                    error_worker_provider_session_missing
                    error_worker_recovery_continuity_invalid
                    error_worker_recovery_reopen_failed
                    error_worker_recovery_send_failed
                    error_worker_recovery_summary_failed
                    error_worker_send_recovery_exhausted
                    error_worker_stale_close_failed
                    error_review_cycle_invalid
                    hoist_review_cycle
                    hoist_review_disposition
                    hoist_review_finding_ledger
                    hoist_recovery_prompt
                    hoist_recovery_worker_provider_session_id
                    hoist_recovery_worker_session_id
                    hoist_worker_provider_session_id
                    hoist_worker_provider_session_id_from_message
                    hoist_worker_provider_session_id_from_status
                    implement
                    inc_review_cycle
                    init_delta_diff
                    init_delta_files
                    init_delta_ranges
                    init_finding_ledger
                    init_review_cycle
                    init_review_defaults
                    inspect_workspace
                    load_committed_change
                    open_worker
                    open_recovery_worker
                    prep_release_mode_only
                    prep_release_mode_remove
                    prep_release_mode_retain
                    prep_review_delta_diff
                    prep_review_delta_files
                    prep_review_delta_ranges
                    release_workspace
                    release_workspace_only
                    retry_recovered_send
                    route_release_mode
                    route_completed_review_cycle
                    route_prepared_review
                    route_review_material
                    review_change
                    route_after_commit
                    route_commit_interaction
                    route_recovery_continuity
                    route_review
                    route_success_workspace_retention
                    status_approval_denied
                    snapshot_review_prior_candidate_commit
                    snapshot_review_prior_commit
                    acp_session_status
                    copy_recovery_pending_prompt
                    copy_worker_provider_session_id_to_session_id
                    inc_worker_send_recovery_count
                    init_worker_send_recovery_count
                    validate
                  ])

  @security_required_nodes Enum.sort(
                             @default_required_nodes ++
                               ~w[
                                 check_security_rework_fresh
                                 compare_security_rework_commit
                                 error_post_validation_committed_change
                                 error_security_rework_not_fresh
                                 hoist_review_attestation_id
                                 post_validation_committed_change
                                 post_validation_expected_commit
                                 prep_review_validation_profile
                                 remember_review_reviewed_commit
                                 remember_validation_reviewed_commit
                                 route_security_after_commit
                                 route_security_attested_auto
                                 route_security_attested_human
                                 route_validated_review
                                 snapshot_validation_prior_candidate_commit
                                 snapshot_validation_prior_commit
                                 inc_validation_review_cycle
                               ]
                           )

  @common_required_actions Enum.sort(~w[
                             acp_close_session
                             acp_session_status
                             acp_send_message
                             acp_start_session
                             coding_workspace_recovery_summary
                             coding_reviewed_commit
                             coding_workspace_acquire
                             coding_workspace_committed_change
                             coding_workspace_inspect
                             coding_workspace_release
                             council_review_change
                           ])

  @required_nested_actions ["consensus_decide_review"]

  @binding_council_review %{
    "action" => "council_review_change",
    "binding" => true
  }

  @optional_reviewed_actions ["git_pr"]

  @mandatory_gate_nodes Enum.sort(~w[
                          validate
                          check_validation_passed
                          commit_change
                          route_after_commit
                          load_committed_change
                          review_change
                          route_review
                        ])

  @publication_nodes Enum.sort(~w[
                       status_change_committed
                       status_pr_created
                       status_human_review_required
                     ])

  @allowed_handlers Enum.sort(~w[start exit transform exec branch gate])
  @allowed_exec_targets ["action"]

  @default_required_actions Enum.sort(["mix_compile" | @common_required_actions])
  @security_required_actions Enum.sort([
                               "coding_security_regression_validate"
                               | @common_required_actions
                             ])
  @cross_app_required_actions Enum.sort([
                                "coding_cross_app_validate"
                                | @common_required_actions
                              ])

  # Closed, sorted action-placement contracts. Node identity pins exact
  # multiplicity; required_dominators / review_required_dominators /
  # required_dominator_sets encode gate dominance over side-effect nodes.
  # Publication for git_pr is a cut-set (route_publish OR route_human_review)
  # so human_required graphs without route_publish still fail closed on early
  # PR edges. Review dominance applies only under binding/human review_profile.
  @common_action_placements Enum.sort_by(
                              [
                                %{
                                  "node_id" => "acquire_workspace",
                                  "action" => "coding_workspace_acquire",
                                  "required_dominators" => [],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "close_worker",
                                  "action" => "acp_close_session",
                                  "required_dominators" => ["open_worker"],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "acp_session_status",
                                  "action" => "acp_session_status",
                                  "required_dominators" => [
                                    "inc_worker_send_recovery_count",
                                    "open_worker"
                                  ],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "close_stale_worker",
                                  "action" => "acp_close_session",
                                  "required_dominators" => [
                                    "check_recovery_provider_id",
                                    "open_worker"
                                  ],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "commit_change",
                                  "action" => "coding_reviewed_commit",
                                  "required_dominators" => [
                                    "check_validation_passed",
                                    "inspect_workspace",
                                    "validate"
                                  ],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "implement",
                                  "action" => "acp_send_message",
                                  "required_dominators" => ["open_worker"],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "coding_workspace_recovery_summary",
                                  "action" => "coding_workspace_recovery_summary",
                                  "required_dominators" => [
                                    "acquire_workspace",
                                    "route_recovery_continuity"
                                  ],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "inspect_workspace",
                                  "action" => "coding_workspace_inspect",
                                  "required_dominators" => ["acquire_workspace"],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "load_committed_change",
                                  "action" => "coding_workspace_committed_change",
                                  "required_dominators" => ["acquire_workspace", "commit_change"],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "open_draft_pr",
                                  "action" => "git_pr",
                                  "required_dominators" => ["route_after_commit"],
                                  "review_required_dominators" => ["route_review"],
                                  "required_dominator_sets" => [
                                    ["route_human_review", "route_publish"]
                                  ]
                                },
                                %{
                                  "node_id" => "open_worker",
                                  "action" => "acp_start_session",
                                  "required_dominators" => ["acquire_workspace"],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "open_recovery_worker",
                                  "action" => "acp_start_session",
                                  "required_dominators" => ["close_stale_worker", "open_worker"],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "release_workspace",
                                  "action" => "coding_workspace_release",
                                  "required_dominators" => ["acquire_workspace"],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "release_workspace_only",
                                  "action" => "coding_workspace_release",
                                  "required_dominators" => ["acquire_workspace"],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "repair_worker_protocol",
                                  "action" => "acp_send_message",
                                  "required_dominators" => ["open_worker"],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "retry_recovered_send",
                                  "action" => "acp_send_message",
                                  "required_dominators" => [
                                    "open_recovery_worker",
                                    "route_recovery_continuity"
                                  ],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                },
                                %{
                                  "node_id" => "review_change",
                                  "action" => "council_review_change",
                                  "required_dominators" => [
                                    "init_finding_ledger",
                                    "init_review_cycle",
                                    "load_committed_change",
                                    "route_prepared_review",
                                    "route_review_material"
                                  ],
                                  "review_required_dominators" => [],
                                  "required_dominator_sets" => []
                                }
                              ],
                              & &1["node_id"]
                            )

  @worker_recovery_policy %{
    "node_attrs" => [
      %{
        "node_id" => "acp_session_status",
        "attrs" => %{
          "type" => "exec",
          "target" => "action",
          "action" => "acp_session_status",
          "context_keys" => "worker_session_id",
          "output_prefix" => "worker_status",
          "max_retries" => "0"
        }
      },
      %{
        "node_id" => "check_recovery_provider_id",
        "attrs" => %{"type" => "branch", "shape" => "diamond", "fan_out" => "false"}
      },
      %{
        "node_id" => "check_worker_send_recovery_budget",
        "attrs" => %{"type" => "branch", "shape" => "diamond", "fan_out" => "false"}
      },
      %{
        "node_id" => "check_worker_status_session_id",
        "attrs" => %{"type" => "branch", "shape" => "diamond", "fan_out" => "false"}
      },
      %{
        "node_id" => "close_stale_worker",
        "attrs" => %{
          "type" => "exec",
          "target" => "action",
          "action" => "acp_close_session",
          "context_keys" => "worker_session_id",
          "param.return_to_pool" => false,
          "output_prefix" => "stale_close",
          "max_retries" => "0"
        }
      },
      %{
        "node_id" => "coding_workspace_recovery_summary",
        "attrs" => %{
          "type" => "exec",
          "target" => "action",
          "action" => "coding_workspace_recovery_summary",
          "context_keys" => "workspace_id,task,pending_prompt",
          "output_prefix" => "recovery",
          "max_retries" => "0"
        }
      },
      %{
        "node_id" => "copy_recovery_pending_prompt",
        "attrs" => %{
          "type" => "transform",
          "transform" => "identity",
          "source_key" => "prompt",
          "output_key" => "pending_prompt"
        }
      },
      %{
        "node_id" => "copy_worker_provider_session_id_to_session_id",
        "attrs" => %{
          "type" => "transform",
          "transform" => "identity",
          "source_key" => "worker_provider_session_id",
          "output_key" => "session_id"
        }
      },
      %{
        "node_id" => "error_worker_provider_session_missing",
        "attrs" => %{
          "type" => "transform",
          "transform" => "constant",
          "expression" => "worker_provider_session_id_missing",
          "output_key" => "error"
        }
      },
      %{
        "node_id" => "error_worker_recovery_continuity_invalid",
        "attrs" => %{
          "type" => "transform",
          "transform" => "constant",
          "expression" => "worker_recovery_continuity_invalid",
          "output_key" => "error"
        }
      },
      %{
        "node_id" => "error_worker_recovery_reopen_failed",
        "attrs" => %{
          "type" => "transform",
          "transform" => "constant",
          "expression" => "worker_recovery_reopen_failed",
          "output_key" => "error"
        }
      },
      %{
        "node_id" => "error_worker_recovery_send_failed",
        "attrs" => %{
          "type" => "transform",
          "transform" => "constant",
          "expression" => "worker_recovery_send_failed",
          "output_key" => "error"
        }
      },
      %{
        "node_id" => "error_worker_recovery_summary_failed",
        "attrs" => %{
          "type" => "transform",
          "transform" => "constant",
          "expression" => "worker_recovery_summary_failed",
          "output_key" => "error"
        }
      },
      %{
        "node_id" => "error_worker_send_recovery_exhausted",
        "attrs" => %{
          "type" => "transform",
          "transform" => "constant",
          "expression" => "worker_send_recovery_exhausted",
          "output_key" => "error"
        }
      },
      %{
        "node_id" => "error_worker_stale_close_failed",
        "attrs" => %{
          "type" => "transform",
          "transform" => "constant",
          "expression" => "worker_stale_close_failed",
          "output_key" => "error"
        }
      },
      %{
        "node_id" => "hoist_recovery_prompt",
        "attrs" => %{
          "type" => "transform",
          "transform" => "identity",
          "source_key" => "recovery.recovery_prompt",
          "output_key" => "prompt"
        }
      },
      %{
        "node_id" => "hoist_recovery_worker_provider_session_id",
        "attrs" => %{
          "type" => "transform",
          "transform" => "identity",
          "source_key" => "worker.session_id",
          "output_key" => "worker_provider_session_id"
        }
      },
      %{
        "node_id" => "hoist_recovery_worker_session_id",
        "attrs" => %{
          "type" => "transform",
          "transform" => "identity",
          "source_key" => "worker.worker_session_id",
          "output_key" => "worker_session_id"
        }
      },
      %{
        "node_id" => "hoist_worker_provider_session_id_from_status",
        "attrs" => %{
          "type" => "transform",
          "transform" => "identity",
          "source_key" => "worker_status.session_id",
          "output_key" => "worker_provider_session_id"
        }
      },
      %{
        "node_id" => "inc_worker_send_recovery_count",
        "attrs" => %{
          "type" => "transform",
          "transform" => "increment",
          "source_key" => "worker_send_recovery_count",
          "output_key" => "worker_send_recovery_count"
        }
      },
      %{
        "node_id" => "init_worker_send_recovery_count",
        "attrs" => %{
          "type" => "transform",
          "transform" => "constant",
          "expression" => "0",
          "output_key" => "worker_send_recovery_count"
        }
      },
      %{
        "node_id" => "retry_recovered_send",
        "attrs" => %{
          "type" => "exec",
          "target" => "action",
          "action" => "acp_send_message",
          "context_keys" => "worker_session_id,prompt,timeout,inactivity_timeout_ms",
          "output_prefix" => "worker_msg",
          "max_retries" => "0"
        }
      },
      %{
        "node_id" => "route_recovery_continuity",
        "attrs" => %{"type" => "branch", "shape" => "diamond", "fan_out" => "false"}
      }
    ],
    "protected_writers" => %{
      "session_id" => ["copy_worker_provider_session_id_to_session_id"],
      "worker_provider_session_id" => [
        "hoist_recovery_worker_provider_session_id",
        "hoist_worker_provider_session_id",
        "hoist_worker_provider_session_id_from_message",
        "hoist_worker_provider_session_id_from_status"
      ],
      "worker_session_id" => ["hoist_recovery_worker_session_id", "hoist_worker_session_id"]
    },
    "edges" => [
      ["acp_session_status", "check_recovery_provider_id", "outcome=fail"],
      ["acp_session_status", "check_worker_status_session_id", "outcome=success"],
      ["build_protocol_repair_prompt", "repair_worker_protocol", nil],
      [
        "check_recovery_provider_id",
        "copy_worker_provider_session_id_to_session_id",
        "context.worker_provider_session_id!=\"\""
      ],
      ["check_recovery_provider_id", "error_worker_provider_session_missing", nil],
      [
        "check_worker_send_recovery_budget",
        "error_worker_send_recovery_exhausted",
        "context.worker_send_recovery_count>=1"
      ],
      [
        "check_worker_send_recovery_budget",
        "inc_worker_send_recovery_count",
        "context.worker_send_recovery_count<1"
      ],
      ["check_worker_status_session_id", "check_recovery_provider_id", nil],
      [
        "check_worker_status_session_id",
        "hoist_worker_provider_session_id_from_status",
        "context.worker_status.session_id!=\"\""
      ],
      ["close_stale_worker", "error_worker_stale_close_failed", "outcome=fail"],
      ["close_stale_worker", "open_recovery_worker", "outcome=success"],
      [
        "coding_workspace_recovery_summary",
        "error_worker_recovery_summary_failed",
        "outcome=fail"
      ],
      ["coding_workspace_recovery_summary", "hoist_recovery_prompt", "outcome=success"],
      ["copy_recovery_pending_prompt", "coding_workspace_recovery_summary", nil],
      ["copy_worker_provider_session_id_to_session_id", "close_stale_worker", nil],
      ["error_worker_provider_session_missing", "status_pipeline_error_then_close", nil],
      ["error_worker_recovery_continuity_invalid", "status_pipeline_error_then_close", nil],
      ["error_worker_recovery_reopen_failed", "status_pipeline_error_then_close", nil],
      ["error_worker_recovery_send_failed", "status_pipeline_error_then_close", nil],
      ["error_worker_recovery_summary_failed", "status_pipeline_error_then_close", nil],
      ["error_worker_send_recovery_exhausted", "status_pipeline_error_then_close", nil],
      ["error_worker_stale_close_failed", "status_pipeline_error_then_close", nil],
      ["hoist_recovery_prompt", "retry_recovered_send", nil],
      ["hoist_recovery_worker_provider_session_id", "route_recovery_continuity", nil],
      ["hoist_recovery_worker_session_id", "hoist_recovery_worker_provider_session_id", nil],
      ["implement", "check_worker_send_recovery_budget", "outcome=fail"],
      ["implement", "hoist_worker_provider_session_id_from_message", "outcome=success"],
      ["inc_worker_send_recovery_count", "acp_session_status", nil],
      ["open_recovery_worker", "error_worker_recovery_reopen_failed", "outcome=fail"],
      ["open_recovery_worker", "hoist_recovery_worker_session_id", "outcome=success"],
      ["repair_worker_protocol", "check_worker_send_recovery_budget", "outcome=fail"],
      [
        "repair_worker_protocol",
        "hoist_worker_provider_session_id_from_message",
        "outcome=success"
      ],
      ["retry_recovered_send", "error_worker_recovery_send_failed", "outcome=fail"],
      [
        "retry_recovered_send",
        "hoist_worker_provider_session_id_from_message",
        "outcome=success"
      ],
      [
        "route_recovery_continuity",
        "copy_recovery_pending_prompt",
        "context.worker.continuity=fresh_recovery"
      ],
      ["route_recovery_continuity", "error_worker_recovery_continuity_invalid", nil],
      ["route_recovery_continuity", "retry_recovered_send", "context.worker.continuity=resumed"]
    ]
  }

  @review_context_keys "diff,files,branch,base_ref,intent,agent_id,workspace_id,commit_hash," <>
                         "review_cycle,finding_ledger,prior_candidate_commit,delta_diff," <>
                         "delta_files,delta_ranges"

  @security_review_context_keys @review_context_keys <>
                                  ",test_paths,validation_profile"

  @rework_budget_node_attrs [
    %{
      "node_id" => "check_operator_rework_category_budget",
      "attrs" => %{
        "type" => "branch",
        "shape" => "diamond",
        "fan_out" => "false"
      }
    },
    %{
      "node_id" => "check_operator_rework_total_budget",
      "attrs" => %{
        "type" => "branch",
        "shape" => "diamond",
        "fan_out" => "false"
      }
    },
    %{
      "node_id" => "check_validation_category_budget",
      "attrs" => %{
        "type" => "branch",
        "shape" => "diamond",
        "fan_out" => "false"
      }
    },
    %{
      "node_id" => "check_validation_total_budget",
      "attrs" => %{
        "type" => "branch",
        "shape" => "diamond",
        "fan_out" => "false"
      }
    },
    %{
      "node_id" => "inc_operator_rework_count",
      "attrs" => %{
        "type" => "transform",
        "transform" => "increment",
        "source_key" => "operator_rework_count",
        "output_key" => "operator_rework_count"
      }
    },
    %{
      "node_id" => "inc_operator_total_rework_count",
      "attrs" => %{
        "type" => "transform",
        "transform" => "increment",
        "source_key" => "total_rework_count",
        "output_key" => "total_rework_count"
      }
    },
    %{
      "node_id" => "inc_review_rework_count",
      "attrs" => %{
        "type" => "transform",
        "transform" => "increment",
        "source_key" => "review_rework_count",
        "output_key" => "review_rework_count"
      }
    },
    %{
      "node_id" => "inc_review_total_rework_count",
      "attrs" => %{
        "type" => "transform",
        "transform" => "increment",
        "source_key" => "total_rework_count",
        "output_key" => "total_rework_count"
      }
    },
    %{
      "node_id" => "inc_validation_rework_count",
      "attrs" => %{
        "type" => "transform",
        "transform" => "increment",
        "source_key" => "validation_rework_count",
        "output_key" => "validation_rework_count"
      }
    },
    %{
      "node_id" => "inc_validation_total_rework_count",
      "attrs" => %{
        "type" => "transform",
        "transform" => "increment",
        "source_key" => "total_rework_count",
        "output_key" => "total_rework_count"
      }
    },
    %{
      "node_id" => "init_operator_rework_count",
      "attrs" => %{
        "type" => "transform",
        "transform" => "constant",
        "expression" => "0",
        "output_key" => "operator_rework_count"
      }
    },
    %{
      "node_id" => "init_review_rework_count",
      "attrs" => %{
        "type" => "transform",
        "transform" => "constant",
        "expression" => "0",
        "output_key" => "review_rework_count"
      }
    },
    %{
      "node_id" => "init_total_rework_count",
      "attrs" => %{
        "type" => "transform",
        "transform" => "constant",
        "expression" => "0",
        "output_key" => "total_rework_count"
      }
    },
    %{
      "node_id" => "init_validation_rework_count",
      "attrs" => %{
        "type" => "transform",
        "transform" => "constant",
        "expression" => "0",
        "output_key" => "validation_rework_count"
      }
    },
    %{
      "node_id" => "mark_operator_rework_iteration",
      "attrs" => %{
        "type" => "transform",
        "transform" => "identity",
        "source_key" => "total_rework_count",
        "output_key" => "rework_iteration"
      }
    },
    %{
      "node_id" => "mark_operator_rework_kind",
      "attrs" => %{
        "type" => "transform",
        "transform" => "constant",
        "expression" => "operator_approval",
        "output_key" => "rework_kind"
      }
    },
    %{
      "node_id" => "mark_review_rework_iteration",
      "attrs" => %{
        "type" => "transform",
        "transform" => "identity",
        "source_key" => "total_rework_count",
        "output_key" => "rework_iteration"
      }
    },
    %{
      "node_id" => "mark_review_rework_kind",
      "attrs" => %{
        "type" => "transform",
        "transform" => "constant",
        "expression" => "review",
        "output_key" => "rework_kind"
      }
    },
    %{
      "node_id" => "mark_validation_rework_iteration",
      "attrs" => %{
        "type" => "transform",
        "transform" => "identity",
        "source_key" => "total_rework_count",
        "output_key" => "rework_iteration"
      }
    },
    %{
      "node_id" => "mark_validation_rework_kind",
      "attrs" => %{
        "type" => "transform",
        "transform" => "constant",
        "expression" => "validation",
        "output_key" => "rework_kind"
      }
    }
  ]

  @review_convergence_node_attrs [
                                   %{
                                     "node_id" => "check_review_category_budget",
                                     "attrs" => %{
                                       "type" => "branch",
                                       "shape" => "diamond",
                                       "fan_out" => "false"
                                     }
                                   },
                                   %{
                                     "node_id" => "check_review_total_budget",
                                     "attrs" => %{
                                       "type" => "branch",
                                       "shape" => "diamond",
                                       "fan_out" => "false"
                                     }
                                   },
                                   %{
                                     "node_id" => "hoist_review_cycle",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "identity",
                                       "source_key" => "review.review_cycle",
                                       "output_key" => "review_cycle"
                                     }
                                   },
                                   %{
                                     "node_id" => "hoist_review_disposition",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "identity",
                                       "source_key" => "review.review_disposition",
                                       "output_key" => "review_disposition"
                                     }
                                   },
                                   %{
                                     "node_id" => "hoist_review_finding_ledger",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "identity",
                                       "source_key" => "review.finding_ledger",
                                       "output_key" => "finding_ledger"
                                     }
                                   },
                                   %{
                                     "node_id" => "inc_review_cycle",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "increment",
                                       "source_key" => "review_cycle",
                                       "output_key" => "review_cycle"
                                     }
                                   },
                                   %{
                                     "node_id" => "init_delta_diff",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "json_extract",
                                       "source_key" => "review_defaults",
                                       "expression" => "delta_diff",
                                       "output_key" => "delta_diff"
                                     }
                                   },
                                   %{
                                     "node_id" => "init_delta_files",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "json_extract",
                                       "source_key" => "review_defaults",
                                       "expression" => "delta_files",
                                       "output_key" => "delta_files"
                                     }
                                   },
                                   %{
                                     "node_id" => "init_delta_ranges",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "json_extract",
                                       "source_key" => "review_defaults",
                                       "expression" => "delta_ranges",
                                       "output_key" => "delta_ranges"
                                     }
                                   },
                                   %{
                                     "node_id" => "init_finding_ledger",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "json_extract",
                                       "source_key" => "review_defaults",
                                       "expression" => "finding_ledger",
                                       "output_key" => "finding_ledger"
                                     }
                                   },
                                   %{
                                     "node_id" => "init_review_cycle",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "json_extract",
                                       "source_key" => "review_defaults",
                                       "expression" => "review_cycle",
                                       "output_key" => "review_cycle"
                                     }
                                   },
                                   %{
                                     "node_id" => "init_review_defaults",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "constant",
                                       "expression" =>
                                         "{\"review_cycle\":1,\"finding_ledger\":{},\"delta_diff\":\"\",\"delta_files\":[],\"delta_ranges\":{}}",
                                       "output_key" => "review_defaults"
                                     }
                                   },
                                   %{
                                     "node_id" => "load_committed_change",
                                     "attrs" => %{
                                       "type" => "exec",
                                       "target" => "action",
                                       "action" => "coding_workspace_committed_change",
                                       "context_keys" => "workspace_id,commit,prior_commit",
                                       "output_prefix" => "change",
                                       "max_retries" => "0"
                                     }
                                   },
                                   %{
                                     "node_id" => "prep_review_delta_diff",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "identity",
                                       "source_key" => "change.delta_diff",
                                       "output_key" => "delta_diff"
                                     }
                                   },
                                   %{
                                     "node_id" => "prep_review_delta_files",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "identity",
                                       "source_key" => "change.delta_files",
                                       "output_key" => "delta_files"
                                     }
                                   },
                                   %{
                                     "node_id" => "prep_review_delta_ranges",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "identity",
                                       "source_key" => "change.delta_ranges",
                                       "output_key" => "delta_ranges"
                                     }
                                   },
                                   %{
                                     "node_id" => "review_change",
                                     "attrs" => %{
                                       "type" => "exec",
                                       "target" => "action",
                                       "action" => "council_review_change",
                                       "context_keys" => @review_context_keys,
                                       "output_prefix" => "review",
                                       "max_retries" => "0"
                                     }
                                   },
                                   %{
                                     "node_id" => "route_completed_review_cycle",
                                     "attrs" => %{
                                       "type" => "branch",
                                       "shape" => "diamond",
                                       "fan_out" => "false"
                                     }
                                   },
                                   %{
                                     "node_id" => "route_prepared_review",
                                     "attrs" => %{
                                       "type" => "branch",
                                       "shape" => "diamond",
                                       "fan_out" => "false"
                                     }
                                   },
                                   %{
                                     "node_id" => "route_review_material",
                                     "attrs" => %{
                                       "type" => "branch",
                                       "shape" => "diamond",
                                       "fan_out" => "false"
                                     }
                                   },
                                   %{
                                     "node_id" => "snapshot_review_prior_candidate_commit",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "identity",
                                       "source_key" => "commit_hash",
                                       "output_key" => "prior_candidate_commit"
                                     }
                                   },
                                   %{
                                     "node_id" => "snapshot_review_prior_commit",
                                     "attrs" => %{
                                       "type" => "transform",
                                       "transform" => "identity",
                                       "source_key" => "commit_hash",
                                       "output_key" => "prior_commit"
                                     }
                                   }
                                 ]
                                 |> Enum.sort_by(& &1["node_id"])

  @review_convergence_node_attrs (@rework_budget_node_attrs ++ @review_convergence_node_attrs)
                                 |> Enum.sort_by(& &1["node_id"])

  @rework_budget_edges [
    [
      "check_operator_rework_category_budget",
      "check_operator_rework_total_budget",
      "context.operator_rework_count<1"
    ],
    [
      "check_operator_rework_category_budget",
      "legacy_status_operator_approval_rework",
      "context.operator_rework_count>=1"
    ],
    [
      "check_validation_category_budget",
      "check_validation_total_budget",
      "context.validation_rework_count<1"
    ],
    [
      "check_validation_category_budget",
      "status_validation_failed",
      "context.validation_rework_count>=1"
    ],
    [
      "inc_operator_rework_count",
      "inc_operator_total_rework_count",
      nil
    ],
    [
      "inc_operator_total_rework_count",
      "mark_operator_rework_kind",
      nil
    ],
    ["inc_review_rework_count", "inc_review_total_rework_count", nil],
    ["inc_review_total_rework_count", "mark_review_rework_kind", nil],
    [
      "inc_validation_rework_count",
      "inc_validation_total_rework_count",
      nil
    ],
    [
      "inc_validation_total_rework_count",
      "mark_validation_rework_kind",
      nil
    ],
    [
      "mark_operator_rework_iteration",
      "build_operator_rework_prompt",
      nil
    ],
    [
      "mark_operator_rework_kind",
      "mark_operator_rework_iteration",
      nil
    ],
    ["mark_review_rework_iteration", "build_review_rework_prompt", nil],
    ["mark_review_rework_kind", "mark_review_rework_iteration", nil],
    [
      "mark_validation_rework_iteration",
      "build_validation_rework_prompt",
      nil
    ],
    [
      "mark_validation_rework_kind",
      "mark_validation_rework_iteration",
      nil
    ],
    ["build_operator_rework_prompt", "reset_worker_turn_protocol_retry_count", nil],
    ["build_review_rework_prompt", "reset_worker_turn_protocol_retry_count", nil],
    ["build_validation_rework_prompt", "reset_worker_turn_protocol_retry_count", nil],
    ["reset_worker_turn_protocol_retry_count", "implement", nil]
  ]

  @review_convergence_edges [
                              [
                                "check_review_category_budget",
                                "check_review_total_budget",
                                "context.review_rework_count<2"
                              ],
                              [
                                "check_review_category_budget",
                                "legacy_status_review_requires_rework",
                                "context.review_rework_count>=2"
                              ],
                              ["hoist_review_cycle", "hoist_review_disposition", nil],
                              [
                                "hoist_review_disposition",
                                "route_completed_review_cycle",
                                nil
                              ],
                              ["hoist_review_finding_ledger", "hoist_review_cycle", nil],
                              ["inc_review_cycle", "inc_review_rework_count", nil],
                              ["prep_review_base", "route_review_material", nil],
                              ["prep_review_delta_diff", "prep_review_delta_files", nil],
                              ["prep_review_delta_files", "prep_review_delta_ranges", nil],
                              ["prep_review_delta_ranges", "route_prepared_review", nil],
                              ["review_change", "error_council_review", "outcome=fail"],
                              [
                                "review_change",
                                "hoist_review_finding_ledger",
                                "outcome=success"
                              ],
                              [
                                "route_completed_review_cycle",
                                "error_review_cycle_invalid",
                                nil
                              ],
                              [
                                "route_completed_review_cycle",
                                "route_review",
                                "context.review_cycle=1"
                              ],
                              [
                                "route_completed_review_cycle",
                                "route_review",
                                "context.review_cycle=2"
                              ],
                              [
                                "route_completed_review_cycle",
                                "route_review",
                                "context.review_cycle=3"
                              ],
                              ["route_prepared_review", "review_change", nil],
                              ["route_review_material", "error_review_cycle_invalid", nil],
                              [
                                "route_review_material",
                                "prep_review_delta_diff",
                                "context.review_cycle=2"
                              ],
                              [
                                "route_review_material",
                                "prep_review_delta_diff",
                                "context.review_cycle=3"
                              ],
                              [
                                "route_review_material",
                                "route_prepared_review",
                                "context.review_cycle=1"
                              ],
                              [
                                "snapshot_review_prior_candidate_commit",
                                "inc_review_cycle",
                                nil
                              ],
                              [
                                "snapshot_review_prior_commit",
                                "snapshot_review_prior_candidate_commit",
                                nil
                              ]
                            ]
                            |> Enum.sort()

  @review_convergence_edges (@rework_budget_edges ++ @review_convergence_edges)
                            |> Enum.sort()

  @review_convergence_policy %{
    "node_attrs" => @review_convergence_node_attrs,
    "protected_writers" => %{
      "delta_diff" => ["init_delta_diff", "prep_review_delta_diff"],
      "delta_files" => ["init_delta_files", "prep_review_delta_files"],
      "delta_ranges" => ["init_delta_ranges", "prep_review_delta_ranges"],
      "finding_ledger" => ["hoist_review_finding_ledger", "init_finding_ledger"],
      "operator_rework_count" => ["inc_operator_rework_count", "init_operator_rework_count"],
      "prior_candidate_commit" => ["snapshot_review_prior_candidate_commit"],
      "prior_commit" => ["snapshot_review_prior_commit"],
      "review_rework_count" => ["inc_review_rework_count", "init_review_rework_count"],
      "review_defaults" => ["init_review_defaults"],
      "review_cycle" => ["hoist_review_cycle", "inc_review_cycle", "init_review_cycle"],
      "review_disposition" => ["hoist_review_disposition"],
      "rework_iteration" => [
        "mark_operator_rework_iteration",
        "mark_review_rework_iteration",
        "mark_validation_rework_iteration"
      ],
      "rework_kind" => [
        "mark_operator_rework_kind",
        "mark_review_rework_kind",
        "mark_validation_rework_kind"
      ],
      "total_rework_count" => [
        "inc_operator_total_rework_count",
        "inc_review_total_rework_count",
        "inc_validation_total_rework_count",
        "init_total_rework_count"
      ],
      "validation_rework_count" => [
        "inc_validation_rework_count",
        "init_validation_rework_count"
      ]
    },
    "edges" => @review_convergence_edges
  }

  @security_review_convergence_policy %{
    "node_attrs" =>
      @review_convergence_node_attrs
      |> Enum.map(fn
        %{"node_id" => "review_change", "attrs" => attrs} = entry ->
          %{entry | "attrs" => Map.put(attrs, "context_keys", @security_review_context_keys)}

        entry ->
          entry
      end)
      |> Kernel.++([
        %{
          "node_id" => "inc_validation_review_cycle",
          "attrs" => %{
            "type" => "transform",
            "transform" => "increment",
            "source_key" => "review_cycle",
            "output_key" => "review_cycle"
          }
        },
        %{
          "node_id" => "snapshot_validation_prior_candidate_commit",
          "attrs" => %{
            "type" => "transform",
            "transform" => "identity",
            "source_key" => "commit_hash",
            "output_key" => "prior_candidate_commit"
          }
        },
        %{
          "node_id" => "snapshot_validation_prior_commit",
          "attrs" => %{
            "type" => "transform",
            "transform" => "identity",
            "source_key" => "commit_hash",
            "output_key" => "prior_commit"
          }
        }
      ])
      |> Enum.sort_by(& &1["node_id"]),
    "protected_writers" => %{
      "delta_diff" => ["init_delta_diff", "prep_review_delta_diff"],
      "delta_files" => ["init_delta_files", "prep_review_delta_files"],
      "delta_ranges" => ["init_delta_ranges", "prep_review_delta_ranges"],
      "finding_ledger" => ["hoist_review_finding_ledger", "init_finding_ledger"],
      "operator_rework_count" => ["inc_operator_rework_count", "init_operator_rework_count"],
      "prior_candidate_commit" => [
        "snapshot_review_prior_candidate_commit",
        "snapshot_validation_prior_candidate_commit"
      ],
      "prior_commit" => ["snapshot_review_prior_commit", "snapshot_validation_prior_commit"],
      "review_rework_count" => ["inc_review_rework_count", "init_review_rework_count"],
      "review_defaults" => ["init_review_defaults"],
      "review_cycle" => [
        "hoist_review_cycle",
        "inc_review_cycle",
        "inc_validation_review_cycle",
        "init_review_cycle"
      ],
      "review_disposition" => ["hoist_review_disposition"],
      "rework_iteration" => [
        "mark_operator_rework_iteration",
        "mark_review_rework_iteration",
        "mark_validation_rework_iteration"
      ],
      "rework_kind" => [
        "mark_operator_rework_kind",
        "mark_review_rework_kind",
        "mark_validation_rework_kind"
      ],
      "total_rework_count" => [
        "inc_operator_total_rework_count",
        "inc_review_total_rework_count",
        "inc_validation_total_rework_count",
        "init_total_rework_count"
      ],
      "validation_rework_count" => [
        "inc_validation_rework_count",
        "init_validation_rework_count"
      ]
    },
    "edges" =>
      @review_convergence_edges
      |> Enum.reject(&(&1 == ["route_prepared_review", "review_change", nil]))
      |> Kernel.++([
        ["inc_validation_review_cycle", "inc_validation_rework_count", nil],
        ["prep_review_validation_profile", "review_change", nil],
        ["route_prepared_review", "prep_review_validation_profile", nil],
        [
          "snapshot_validation_prior_candidate_commit",
          "inc_validation_review_cycle",
          nil
        ],
        [
          "snapshot_validation_prior_commit",
          "snapshot_validation_prior_candidate_commit",
          nil
        ]
      ])
      |> Enum.sort()
  }

  @default_action_placements Enum.sort_by(
                               [
                                 %{
                                   "node_id" => "validate",
                                   "action" => "mix_compile",
                                   "required_dominators" => ["inspect_workspace"],
                                   "review_required_dominators" => [],
                                   "required_dominator_sets" => []
                                 }
                                 | @common_action_placements
                               ],
                               & &1["node_id"]
                             )

  @cross_app_action_placements Enum.sort_by(
                                 [
                                   %{
                                     "node_id" => "validate",
                                     "action" => "coding_cross_app_validate",
                                     "required_dominators" => [
                                       "acquire_workspace",
                                       "inspect_workspace"
                                     ],
                                     "review_required_dominators" => [],
                                     "required_dominator_sets" => []
                                   }
                                   | @common_action_placements
                                 ],
                                 & &1["node_id"]
                               )

  # Security validates after review: commit is pre-validation, so do not require
  # validate/check_validation_passed to dominate commit_change.
  @security_action_placements Enum.sort_by(
                                [
                                  %{
                                    "node_id" => "commit_change",
                                    "action" => "coding_reviewed_commit",
                                    "required_dominators" => ["inspect_workspace"],
                                    "review_required_dominators" => [],
                                    "required_dominator_sets" => []
                                  },
                                  %{
                                    "node_id" => "post_validation_committed_change",
                                    "action" => "coding_workspace_committed_change",
                                    "required_dominators" => [
                                      "check_validation_passed",
                                      "hoist_review_attestation_id",
                                      "validate"
                                    ],
                                    "review_required_dominators" => [],
                                    "required_dominator_sets" => []
                                  },
                                  %{
                                    "node_id" => "validate",
                                    "action" => "coding_security_regression_validate",
                                    "required_dominators" => [
                                      "hoist_review_attestation_id",
                                      "load_committed_change",
                                      "review_change",
                                      "route_review"
                                    ],
                                    "review_required_dominators" => [],
                                    "required_dominator_sets" => []
                                  }
                                  | Enum.reject(
                                      @common_action_placements,
                                      &(&1["node_id"] == "commit_change")
                                    )
                                ],
                                & &1["node_id"]
                              )

  @semantic_policy_base %{
    "allowed_handlers" => @allowed_handlers,
    "allowed_exec_targets" => @allowed_exec_targets,
    "optional_actions" => @optional_reviewed_actions,
    "mandatory_gate_nodes" => @mandatory_gate_nodes,
    "publication_nodes" => @publication_nodes,
    "validation_gate" => "validate",
    "validation_result_gate" => "check_validation_passed",
    "post_validation_commit_routing" => "route_after_commit",
    "committed_change_routing" => "route_after_commit",
    "review_gate" => "review_change",
    "review_routing_gate" => "route_review",
    "worker_recovery" => @worker_recovery_policy,
    "review_convergence" => @review_convergence_policy,
    "action_placements" => []
  }

  @security_semantic_nodes %{
    "attestation_source" => "hoist_review_attestation_id",
    "committed_candidate_join" => "route_security_after_commit",
    "committed_material_gate" => "load_committed_change",
    "post_validation_exact_head_check" => "post_validation_committed_change",
    "post_validation_routing" => "route_validated_review"
  }

  @profiles [
              %{
                "id" => "default",
                "executable" => true,
                "template_version" => @template_version,
                "required_nodes" => @default_required_nodes,
                "required_actions" => @default_required_actions,
                "validation_strategy" => %{"action" => "mix_compile"},
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  @semantic_policy_base
                  |> Map.put("validation_profile", "default")
                  |> Map.put("action_placements", @default_action_placements)
                  |> Map.put(
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@default_required_actions ++ @optional_reviewed_actions))
                  )
              },
              %{
                "id" => "security_regression",
                "executable" => true,
                "template_version" => @template_version,
                "required_nodes" => @security_required_nodes,
                "required_actions" => @security_required_actions,
                "validation_strategy" => %{
                  "action" => "coding_security_regression_validate",
                  "authority_parameter" => "review_attestation_id",
                  "authority_source" => "review.review_attestation_id",
                  "per_revision_timeout_default_ms" => 300_000,
                  "per_revision_timeout_max_ms" => 600_000,
                  "uses_default_timeout" => true,
                  "two_revision" => true
                },
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  @semantic_policy_base
                  |> Map.merge(@security_semantic_nodes)
                  |> Map.put("review_convergence", @security_review_convergence_policy)
                  |> Map.put("validation_profile", "security_regression")
                  |> Map.put("mandatory_gate_nodes", @security_required_nodes)
                  |> Map.put("post_validation_commit_routing", "route_validated_review")
                  |> Map.put("action_placements", @security_action_placements)
                  |> Map.put(
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@security_required_actions ++ @optional_reviewed_actions))
                  )
              },
              %{
                "id" => "contract_change",
                "executable" => false,
                "template_version" => @template_version,
                "required_nodes" => @default_required_nodes,
                "required_actions" => @common_required_actions,
                "validation_strategy" => %{
                  "required_enforcement" =>
                    "contract_rules_preflight_and_consumer_api_compatibility"
                },
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  @semantic_policy_base
                  |> Map.put("validation_profile", "contract_change")
                  |> Map.put(
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@common_required_actions ++ @optional_reviewed_actions))
                  ),
                "unsupported_reason" =>
                  "No registered action enforces CONTRACT_RULES preflight and consumer/API " <>
                    "compatibility review for contract changes."
              },
              %{
                "id" => "frontend_visual",
                "executable" => false,
                "template_version" => @template_version,
                "required_nodes" => @default_required_nodes,
                "required_actions" => @common_required_actions,
                "validation_strategy" => %{
                  "required_enforcement" =>
                    "playwright_interaction_and_desktop_mobile_visual_evidence"
                },
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  @semantic_policy_base
                  |> Map.put("validation_profile", "frontend_visual")
                  |> Map.put(
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@common_required_actions ++ @optional_reviewed_actions))
                  ),
                "unsupported_reason" =>
                  "No registered action contract produces and verifies Playwright interaction " <>
                    "plus desktop/mobile visual evidence."
              },
              %{
                "id" => "docs_only",
                "executable" => false,
                "template_version" => @template_version,
                "required_nodes" => @default_required_nodes,
                "required_actions" => @common_required_actions,
                "validation_strategy" => %{
                  "required_enforcement" => "documentation_checks"
                },
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  @semantic_policy_base
                  |> Map.put("validation_profile", "docs_only")
                  |> Map.put(
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@common_required_actions ++ @optional_reviewed_actions))
                  ),
                "unsupported_reason" =>
                  "No registered documentation-validation action contract exists; " <>
                    "mix_compile is not an enforceable substitute for documentation checks."
              },
              %{
                "id" => "cross_app",
                "executable" => true,
                "template_version" => @template_version,
                "required_nodes" => @default_required_nodes,
                "required_actions" => @cross_app_required_actions,
                "validation_strategy" => %{
                  "action" => "coding_cross_app_validate",
                  "authority_parameter" => "workspace_id",
                  "authority_source" => "workspace_id",
                  "per_check_timeout_default_ms" => 300_000,
                  "per_check_timeout_max_ms" => 600_000,
                  "uses_default_timeout" => true,
                  "selects_downstream_dependents" => true,
                  "runs_xref_graph_evidence" => true,
                  "claims_zero_cycles" => false
                },
                "review_strategy" => @binding_council_review,
                "semantic_policy" =>
                  @semantic_policy_base
                  |> Map.put("validation_profile", "cross_app")
                  |> Map.put("action_placements", @cross_app_action_placements)
                  |> Map.put(
                    "allowed_actions",
                    Enum.sort(
                      Enum.uniq(@cross_app_required_actions ++ @optional_reviewed_actions)
                    )
                  )
              },
              %{
                "id" => "database_migration",
                "executable" => false,
                "template_version" => @template_version,
                "required_nodes" => @default_required_nodes,
                "required_actions" => @common_required_actions,
                "validation_strategy" => %{
                  "required_enforcement" => "reversible_database_migration_checks"
                },
                "review_strategy" => %{
                  "action" => "council_review_change",
                  "binding" => true,
                  "human_gate" => "required",
                  "unattended_publication" => "forbidden"
                },
                "semantic_policy" =>
                  @semantic_policy_base
                  |> Map.put("validation_profile", "database_migration")
                  |> Map.put(
                    "allowed_actions",
                    Enum.sort(Enum.uniq(@common_required_actions ++ @optional_reviewed_actions))
                  ),
                "unsupported_reason" =>
                  "No enforceable migration action contract combines reversible migration " <>
                    "checks, a mandatory human gate, and prohibition of unattended publication."
              }
            ]
            |> Enum.map(&Map.put(&1, "required_nested_actions", @required_nested_actions))
            |> Enum.sort_by(& &1["id"])

  @profiles_by_id Map.new(@profiles, &{&1["id"], &1})

  @type json_value ::
          nil | boolean() | number() | String.t() | [json_value()] | %{String.t() => json_value()}
  @type descriptor :: %{String.t() => json_value()}
  @type profile_selector :: String.t() | descriptor()
  @type inventory :: %{
          required(:nodes) => [String.t()] | MapSet.t(String.t()) | map(),
          required(:actions) => [String.t()] | MapSet.t(String.t()) | map()
        }
  @type requirement_error ::
          {:unknown_profile, term()}
          | {:profile_not_executable, String.t(), String.t()}
          | {:missing_requirements, %{required(String.t()) => [String.t()]}}
          | :invalid_requirement_inventory

  @doc "Returns every declared profile, sorted by profile ID."
  @spec all() :: [descriptor()]
  def all, do: @profiles

  @doc "Returns every declared profile ID in lexical order."
  @spec known_ids() :: [String.t()]
  def known_ids, do: Enum.map(@profiles, & &1["id"])

  @doc "Fetches a declared profile without changing or defaulting its ID."
  @spec fetch(term()) :: {:ok, descriptor()} | {:error, {:unknown_profile, term()}}
  def fetch(id) do
    case Map.fetch(@profiles_by_id, id) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, {:unknown_profile, id}}
    end
  end

  @doc "Fetches a profile only when all of its reviewed enforcement contracts exist."
  @spec fetch_executable(term()) ::
          {:ok, descriptor()}
          | {:error,
             {:unknown_profile, term()} | {:profile_not_executable, String.t(), String.t()}}
  def fetch_executable(id) do
    with {:ok, profile} <- fetch(id) do
      if profile["executable"] do
        {:ok, profile}
      else
        {:error, {:profile_not_executable, profile["id"], profile["unsupported_reason"]}}
      end
    end
  end

  @doc "Verifies that a compiled execution manifest contains reviewed nested actions."
  @spec validate_execution_manifest(descriptor(), map()) ::
          :ok | {:error, {:missing_nested_actions, [String.t()]}} | {:error, :invalid_manifest}
  def validate_execution_manifest(
        %{"required_nested_actions" => required},
        %{"actions" => actions}
      )
      when is_list(required) and is_list(actions) do
    present =
      actions
      |> Enum.flat_map(fn
        %{"name" => name} when is_binary(name) -> [name]
        _other -> []
      end)
      |> MapSet.new()

    missing = Enum.reject(required, &MapSet.member?(present, &1))

    if missing == [], do: :ok, else: {:error, {:missing_nested_actions, Enum.sort(missing)}}
  end

  def validate_execution_manifest(_profile, _manifest), do: {:error, :invalid_manifest}

  @doc """
  Verifies that a graph or inventory contains every node and action required by
  a profile.

  The canonical call order is `validate_requirements(profile, graph)`. Graphs
  expose action names through each node's `"action"` attribute. A lightweight
  `%{nodes: ..., actions: ...}` inventory is accepted for deterministic unit
  tests and compiler boundaries. Subject-first calls are also accepted.
  """
  @spec validate_requirements(
          profile_selector() | Graph.t() | inventory(),
          profile_selector() | Graph.t() | inventory()
        ) ::
          :ok | {:error, requirement_error()}
  def validate_requirements(%Graph{} = graph, profile_or_id) do
    validate_profile_requirements(profile_or_id, graph)
  end

  def validate_requirements(%{nodes: _nodes, actions: _actions} = inventory, profile_or_id) do
    validate_profile_requirements(profile_or_id, inventory)
  end

  def validate_requirements(
        %{"nodes" => _nodes, "actions" => _actions} = inventory,
        profile_or_id
      ) do
    validate_profile_requirements(profile_or_id, inventory)
  end

  def validate_requirements(profile_or_id, graph_or_inventory) do
    validate_profile_requirements(profile_or_id, graph_or_inventory)
  end

  defp validate_profile_requirements(profile_or_id, graph_or_inventory) do
    with {:ok, profile} <- resolve_profile(profile_or_id),
         {:ok, inventory} <- requirement_inventory(graph_or_inventory) do
      missing = %{
        "missing_nodes" => missing(profile["required_nodes"], inventory.nodes),
        "missing_actions" => missing(profile["required_actions"], inventory.actions)
      }

      if missing == %{"missing_nodes" => [], "missing_actions" => []} do
        :ok
      else
        {:error, {:missing_requirements, missing}}
      end
    end
  end

  defp resolve_profile(%{"id" => id}), do: fetch(id)
  defp resolve_profile(id), do: fetch(id)

  defp requirement_inventory(%Graph{nodes: nodes}) do
    normalize_inventory(Map.keys(nodes), Enum.flat_map(nodes, &node_action/1))
  end

  defp requirement_inventory(%{nodes: nodes, actions: actions}) do
    normalize_inventory(nodes, actions)
  end

  defp requirement_inventory(%{"nodes" => nodes, "actions" => actions}) do
    normalize_inventory(nodes, actions)
  end

  defp requirement_inventory(_other), do: {:error, :invalid_requirement_inventory}

  defp normalize_inventory(nodes, actions) do
    with {:ok, nodes} <- string_set(nodes),
         {:ok, actions} <- string_set(actions) do
      {:ok, %{nodes: nodes, actions: actions}}
    else
      :error -> {:error, :invalid_requirement_inventory}
    end
  end

  defp string_set(%MapSet{} = values), do: string_set(MapSet.to_list(values))
  defp string_set(values) when is_map(values), do: string_set(Map.keys(values))

  defp string_set(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, MapSet.new(values)}
    else
      :error
    end
  end

  defp string_set(_values), do: :error

  defp node_action({_id, %{attrs: attrs}}) when is_map(attrs) do
    case Map.get(attrs, "action") || Map.get(attrs, :action) do
      action when is_binary(action) and action != "" -> [action]
      _other -> []
    end
  end

  defp node_action(_node), do: []

  defp missing(required, actual) do
    Enum.reject(required, &MapSet.member?(actual, &1))
  end
end
