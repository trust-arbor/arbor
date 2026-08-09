defmodule Arbor.Agent.TemplateAuthorityReconciliationCore do
  @moduledoc """
  Pure, **policy-neutral** reconciliation **diff** core for authority-only
  template policy.

  Compares two caller-supplied authority sets (typically a desired view from
  `Arbor.Agent.TemplateAuthorityPolicy` and an actual view the caller already
  scoped) and reports set-membership labels:

  - `retained` — present on both sides with equal normalized content
  - `added` — present only in the desired set
  - `removed` — present only in the actual set
  - `changed` — same identity key on both sides with different content

  Normalization is **not** reimplemented here. Both sides are admitted only
  through `TemplateAuthorityPolicy.normalize_authority_view/1` (or
  `validate_envelope/1` for full envelopes), so declared and live views share
  one bounded, conflict-rejecting path. Supplied envelope digests are verified
  and never discarded.

  ## What this core does NOT do

  - Does **not** infer template ownership. Legacy coding-agent grants often have
    `nil` source metadata; baseline/external grants can coexist. Source /
    metadata fields are ignored and never consulted.
  - Does **not** treat every live capability as template-owned. The caller must
    supply the actual set they want compared — this core diffs only those sets.
  - Does **not** encode grant, revoke, or apply decisions. Bucket names are
    set-diff labels only (`removed` ≠ "must revoke"). Ownership classification
    and mutation belong to a later explicit imperative reconciliation boundary.
  - Does **not** touch Lifecycle, Security, Trust, Gateway, or MCP.

  Guarantees: pure, JSON-clean, bounded string-keyed maps, no capability IDs.
  """

  alias Arbor.Agent.TemplateAuthorityPolicy

  @version 1
  @kind "template_authority_reconciliation_diff"

  @type json_scalar :: String.t() | number() | boolean() | nil
  @type json_value :: json_scalar() | [json_value()] | %{optional(String.t()) => json_value()}
  @type diff :: %{optional(String.t()) => json_value()}

  @doc """
  Diff two caller-supplied authority sets.

  Either side may be:

  - a full authority envelope (`snapshot` + `digest`) — admitted only after
    `TemplateAuthorityPolicy.validate_envelope/1`
  - a raw authority map (`capabilities` + `trust_preset` / `trust`)
  - Capability-struct live rows inside the capability list

  All normalization, bounds, conflict rejection, and digest verification are
  delegated to `TemplateAuthorityPolicy`. This module only computes set-diff
  membership labels — no action list, revoke intents, or ownership fields.
  """
  @spec diff(map(), map()) :: {:ok, diff()} | {:error, term()}
  def diff(desired, actual) when is_map(desired) and is_map(actual) do
    with {:ok, desired_view} <- admit(desired),
         {:ok, actual_view} <- admit(actual) do
      capability_diff =
        diff_capabilities(desired_view["capabilities"], actual_view["capabilities"])

      trust_diff = diff_trust(desired_view["trust_preset"], actual_view["trust_preset"])

      report = %{
        "version" => @version,
        "kind" => @kind,
        "capabilities" => capability_diff,
        "trust" => trust_diff,
        "summary" => %{
          "capabilities" => counts(capability_diff),
          "trust_rules" => counts(trust_diff["rules"]),
          "trust_baseline_changed" => trust_diff["baseline"]["status"] == "changed"
        }
      }

      {:ok, report}
    end
  end

  def diff(_desired, _actual), do: error(:invalid_diff_input)

  @doc """
  True when the set-diff reports no capability or trust membership changes.

  This is not an apply/ownership decision — only "the two supplied sets match".
  """
  @spec unchanged?(diff()) :: boolean()
  def unchanged?(%{
        "capabilities" => caps,
        "trust" => %{"baseline" => baseline, "rules" => rules}
      })
      when is_map(caps) and is_map(rules) and is_map(baseline) do
    baseline["status"] == "retained" and
      caps["added"] == [] and
      caps["removed"] == [] and
      caps["changed"] == [] and
      rules["added"] == [] and
      rules["removed"] == [] and
      rules["changed"] == []
  end

  def unchanged?(_diff), do: false

  @spec kind() :: String.t()
  def kind, do: @kind

  @spec version() :: pos_integer()
  def version, do: @version

  # ---------------------------------------------------------------------------
  # Admit via the single policy normalization path
  # ---------------------------------------------------------------------------

  defp admit(input) do
    case TemplateAuthorityPolicy.normalize_authority_view(input) do
      {:ok, view} ->
        {:ok, view}

      {:error, {:template_authority_policy, reason}} ->
        error(reason)

      {:error, reason} ->
        error(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Set-diff only (membership labels — not mutation intents)
  # ---------------------------------------------------------------------------

  defp diff_capabilities(desired, actual) do
    desired_by = Map.new(desired, &{&1["resource"], &1})
    actual_by = Map.new(actual, &{&1["resource"], &1})

    resources =
      MapSet.union(MapSet.new(Map.keys(desired_by)), MapSet.new(Map.keys(actual_by)))
      |> Enum.sort()

    init = %{"retained" => [], "added" => [], "removed" => [], "changed" => []}

    Enum.reduce(resources, init, fn resource, acc ->
      case {Map.get(desired_by, resource), Map.get(actual_by, resource)} do
        {desired_cap, nil} ->
          push(acc, "added", strip_capability(desired_cap))

        {nil, actual_cap} ->
          push(acc, "removed", strip_capability(actual_cap))

        {desired_cap, actual_cap} ->
          if desired_cap["constraints"] == actual_cap["constraints"] do
            push(acc, "retained", strip_capability(desired_cap))
          else
            push(acc, "changed", %{
              "resource" => resource,
              "desired" => %{"constraints" => desired_cap["constraints"]},
              "actual" => %{"constraints" => actual_cap["constraints"]}
            })
          end
      end
    end)
  end

  defp diff_trust(desired, actual) do
    baseline_status =
      if desired["baseline"] == actual["baseline"], do: "retained", else: "changed"

    desired_rules = desired["rules"] || %{}
    actual_rules = actual["rules"] || %{}

    uris =
      MapSet.union(MapSet.new(Map.keys(desired_rules)), MapSet.new(Map.keys(actual_rules)))
      |> Enum.sort()

    init = %{"retained" => [], "added" => [], "removed" => [], "changed" => []}

    rules =
      Enum.reduce(uris, init, fn uri, acc ->
        case {Map.get(desired_rules, uri), Map.get(actual_rules, uri)} do
          {desired_mode, nil} ->
            push(acc, "added", %{"uri" => uri, "mode" => desired_mode})

          {nil, actual_mode} ->
            push(acc, "removed", %{"uri" => uri, "mode" => actual_mode})

          {desired_mode, actual_mode} when desired_mode == actual_mode ->
            push(acc, "retained", %{"uri" => uri, "mode" => desired_mode})

          {desired_mode, actual_mode} ->
            push(acc, "changed", %{
              "uri" => uri,
              "desired" => desired_mode,
              "actual" => actual_mode
            })
        end
      end)

    %{
      "baseline" => %{
        "status" => baseline_status,
        "desired" => desired["baseline"],
        "actual" => actual["baseline"]
      },
      "rules" => rules
    }
  end

  defp strip_capability(%{"resource" => resource, "constraints" => constraints}) do
    %{"resource" => resource, "constraints" => constraints}
  end

  defp push(acc, key, entry), do: Map.update!(acc, key, &(&1 ++ [entry]))

  defp counts(%{
         "retained" => retained,
         "added" => added,
         "removed" => removed,
         "changed" => changed
       }) do
    %{
      "retained" => length(retained),
      "added" => length(added),
      "removed" => length(removed),
      "changed" => length(changed)
    }
  end

  defp error(reason), do: {:error, {:template_authority_reconciliation, reason}}
end
