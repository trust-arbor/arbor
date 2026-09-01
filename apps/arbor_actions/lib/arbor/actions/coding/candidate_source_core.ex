defmodule Arbor.Actions.Coding.CandidateSourceCore do
  @moduledoc """
  Pure closed discriminator for review, publication, and adoption sources.

  Admission inspects raw maps/keyword lists before any atom/string key collapse.
  """

  @type source :: :workspace_branch | :immutable_object
  @type provenance :: :created | :reused | :unknown
  @type evidence_mode :: :archive_from_branch | :verify_existing
  @type retirement :: {:compare_delete, String.t()} | :preserve

  @closed_values %{
    :workspace_branch => :workspace_branch,
    "workspace_branch" => :workspace_branch,
    :immutable_object => :immutable_object,
    "immutable_object" => :immutable_object
  }

  @doc false
  @spec admit(term()) ::
          {:ok, source()} | {:error, :ambiguous_candidate_source | :invalid_candidate_source}
  def admit(opts) when is_list(opts) do
    atom_key? = Keyword.has_key?(opts, :candidate_source)
    string_pair = List.keyfind(opts, "candidate_source", 0)

    admit_keys(atom_key?, is_tuple(string_pair), fn
      :atom -> Keyword.get(opts, :candidate_source)
      :string -> elem(string_pair, 1)
    end)
  end

  def admit(opts) when is_map(opts) do
    atom_key? = Map.has_key?(opts, :candidate_source)
    string_key? = Map.has_key?(opts, "candidate_source")

    admit_keys(atom_key?, string_key?, fn
      :atom -> Map.get(opts, :candidate_source)
      :string -> Map.get(opts, "candidate_source")
    end)
  end

  def admit(_opts), do: {:error, :invalid_candidate_source}

  @doc false
  @spec review_expected_head(source(), String.t(), String.t()) :: String.t()
  def review_expected_head(:workspace_branch, _base, candidate), do: candidate
  def review_expected_head(:immutable_object, base, _candidate), do: base

  @doc false
  @spec review_requires_pinned_evidence?(source()) :: boolean()
  def review_requires_pinned_evidence?(:immutable_object), do: true
  def review_requires_pinned_evidence?(:workspace_branch), do: false

  @doc false
  @spec publish_evidence_mode(source()) :: evidence_mode()
  def publish_evidence_mode(:immutable_object), do: :verify_existing
  def publish_evidence_mode(:workspace_branch), do: :archive_from_branch

  @doc false
  @spec adoption_evidence_mode(source()) :: evidence_mode()
  def adoption_evidence_mode(source), do: publish_evidence_mode(source)

  @doc false
  @spec branch_retirement_expected_oid(source(), term(), String.t(), String.t()) :: retirement()
  def branch_retirement_expected_oid(source, provenance, base, candidate)
      when is_binary(base) and is_binary(candidate) do
    case {source, normalize_provenance(provenance)} do
      {:immutable_object, :created} -> {:compare_delete, base}
      {:workspace_branch, :created} -> {:compare_delete, candidate}
      {_source, _provenance} -> :preserve
    end
  end

  @doc false
  @spec workspace_branch_still_at_impossible_base?(source(), term(), String.t(), String.t()) ::
          boolean()
  def workspace_branch_still_at_impossible_base?(:workspace_branch, branch_oid, base, candidate)
      when is_binary(branch_oid) and is_binary(base) and is_binary(candidate) do
    base_oid = normalize_oid(base)
    candidate_oid = normalize_oid(candidate)
    observed = normalize_oid(branch_oid)

    base_oid != candidate_oid and observed == base_oid
  end

  def workspace_branch_still_at_impossible_base?(_source, _branch_oid, _base, _candidate),
    do: false

  defp admit_keys(true, true, _fetch), do: {:error, :ambiguous_candidate_source}
  defp admit_keys(false, false, _fetch), do: {:ok, :workspace_branch}
  defp admit_keys(true, false, fetch), do: admit_value(fetch.(:atom))
  defp admit_keys(false, true, fetch), do: admit_value(fetch.(:string))

  defp admit_value(value) do
    case Map.fetch(@closed_values, value) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, :invalid_candidate_source}
    end
  end

  defp normalize_provenance(provenance) when provenance in [:created, "created"], do: :created
  defp normalize_provenance(provenance) when provenance in [:reused, "reused"], do: :reused
  defp normalize_provenance(provenance) when provenance in [:unknown, "unknown"], do: :unknown
  defp normalize_provenance(_provenance), do: :unknown

  defp normalize_oid(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
end
