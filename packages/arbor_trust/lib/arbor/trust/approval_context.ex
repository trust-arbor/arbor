defmodule Arbor.Trust.ApprovalContext do
  @moduledoc """
  Build the trust-side explanation that rides along with an approval request.

  When `ApprovalGuard` escalates a capability use to a human, the prompt the
  human sees should answer two questions the bare resource URI cannot:

    * **Why is it asking?** Which trust rule matched, what the baseline and
      security ceiling were, and what the effective mode resolved to.
    * **What is at stake?** The capability profile's reversibility, blast
      radius, and effect class, plus whether earned autonomy could ever make
      this automatic (`graduation_threshold`).

  Both already exist in the trust layer (`Arbor.Trust.Policy.explain/3` and
  `Arbor.Trust.CapabilityProfileRegistry.profile_for/1`); this module is the
  last-mile wiring that carries them into the approval request metadata as a
  JSON-clean map. The map is display-only: it is never consulted for the
  authorization decision itself, and every lookup fails soft to `nil` so a
  trust-side outage cannot block the escalation path.

  The two lookups are injectable through `:explain_fun` / `:profile_fun` so
  the shape can be unit-tested without the policy host.
  """

  alias Arbor.Contracts.Security.CapabilityProfile
  alias Arbor.Trust.CapabilityProfileRegistry
  alias Arbor.Trust.CapabilityRiskProfiles
  alias Arbor.Trust.Config

  @type t :: %{optional(atom()) => term()}

  @explain_opt_keys [:model_class, :egress_tier, :egress_mode, :security_ceilings]
  @modes [:block, :ask, :allow, :auto]

  @doc """
  Build the trust context for `principal_id` using `resource_uri`.

  Returns a compacted map with `:effective_mode`, `:user_mode`, `:baseline`,
  `:matched_rule`, `:security_ceiling`, `:ceiling_match`, and `:profile`
  (each present only when resolvable). Never raises.
  """
  @spec build(String.t(), String.t(), keyword() | map()) :: t()
  def build(principal_id, resource_uri, opts \\ []) do
    explain_fun = option(opts, :explain_fun) || default_explain_fun()
    profile_fun = option(opts, :profile_fun) || (&CapabilityProfileRegistry.profile_for/1)

    explanation =
      safe_apply(fn -> explain_fun.(principal_id, resource_uri, explain_opts(opts)) end)

    profile = safe_apply(fn -> profile_fun.(resource_uri) end)

    %{}
    |> merge_explanation(explanation)
    |> Map.put(:profile, profile_summary(profile))
    |> compact()
  end

  @doc """
  Summarise a `CapabilityProfile` for display: the risk axes plus the
  graduation threshold derived from them. Returns `nil` for anything that is
  not a profile.
  """
  @spec profile_summary(CapabilityProfile.t() | term()) :: map() | nil
  def profile_summary(%CapabilityProfile{} = profile) do
    %{
      uri_prefix: profile.uri_prefix,
      reversibility: profile.reversibility,
      blast_radius: profile.blast_radius,
      effect_class: profile.effect_class,
      data_class: profile.data_class,
      cost_class: profile.cost_class,
      default_approval: profile.default_approval,
      graduation_eligible: profile.graduation_eligible,
      graduation_threshold: CapabilityRiskProfiles.graduation_threshold(profile)
    }
  end

  def profile_summary(_other), do: nil

  # -- explanation ------------------------------------------------------------

  defp merge_explanation(acc, explanation) when is_map(explanation) do
    acc
    |> Map.put(:effective_mode, mode(Map.get(explanation, :effective_mode)))
    |> Map.put(:user_mode, mode(Map.get(explanation, :user_mode)))
    |> Map.put(:baseline, mode(Map.get(explanation, :baseline)))
    |> Map.put(:security_ceiling, mode(Map.get(explanation, :security_ceiling)))
    |> Map.put(:matched_rule, match(Map.get(explanation, :user_match)))
    |> Map.put(:ceiling_match, match(Map.get(explanation, :ceiling_match)))
    |> Map.put(:explain_error, explain_error(Map.get(explanation, :error)))
  end

  defp merge_explanation(acc, _not_a_map), do: acc

  defp mode(value) when value in @modes, do: value
  defp mode(_), do: nil

  defp match({prefix, value}) when is_binary(prefix) and value in @modes,
    do: %{prefix: prefix, mode: value}

  defp match(%{prefix: prefix, mode: value}) when is_binary(prefix) and value in @modes,
    do: %{prefix: prefix, mode: value}

  defp match(_), do: nil

  defp explain_error(nil), do: nil
  defp explain_error(reason) when is_atom(reason), do: reason
  defp explain_error(reason), do: inspect(reason, limit: 10)

  defp default_explain_fun do
    policy = Config.policy_module()

    fn principal_id, resource_uri, opts ->
      if Code.ensure_loaded?(policy) and function_exported?(policy, :explain, 3) do
        apply(policy, :explain, [principal_id, resource_uri, opts])
      else
        nil
      end
    end
  end

  # `Policy.explain/3` admits only a small, validated option set; pass the
  # subset that affects resolution and let the policy reject bad values.
  defp explain_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.take(opts, @explain_opt_keys), else: []
  end

  defp explain_opts(opts) when is_map(opts) do
    Enum.flat_map(@explain_opt_keys, fn key ->
      case Map.fetch(opts, key) do
        {:ok, value} -> [{key, value}]
        :error -> []
      end
    end)
  end

  defp explain_opts(_), do: []

  # -- plumbing ---------------------------------------------------------------

  defp option(opts, key) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, key), else: nil
  end

  defp option(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp option(_, _), do: nil

  defp safe_apply(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
