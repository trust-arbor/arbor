defmodule Arbor.Commands.CodingBenchmark.ExactTargetTreeVerifier do
  @moduledoc false

  # Trusted built-in objective verifier for the closed selector "exact_target_tree".
  # Compares the final canonical HEAD tree of the request workdir with a fixture-bound
  # target tree OID from validated publication evidence. Never exposes the target OID
  # in request material or pass/fail detail.

  alias Arbor.Commands.CodingBenchmark.Git

  @selector "exact_target_tree"
  @oid_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @id_pattern ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @max_timeout_ms 3_600_000

  @doc false
  @spec selector() :: String.t()
  def selector, do: @selector

  @doc """
  Build a unary verifier callback closed over validated fixture→target-tree bindings.

  The callback admits only the standard harness verifier request keys and returns
  `:ok` or `{:error, reason}` without embedding target OIDs in the reason.
  """
  @spec build(%{optional(String.t()) => String.t()}, pos_integer()) :: (map() -> term())
  def build(targets, timeout_ms)
      when is_map(targets) and is_integer(timeout_ms) and timeout_ms > 0 and
             timeout_ms <= @max_timeout_ms do
    frozen = freeze_targets(targets)

    fn request when is_map(request) and not is_struct(request) ->
      verify(request, frozen, timeout_ms)
    end
  end

  defp freeze_targets(targets) do
    Map.new(targets, fn {fixture_id, target_tree_oid} ->
      unless is_binary(fixture_id) and Regex.match?(@id_pattern, fixture_id) do
        raise ArgumentError, "invalid exact_target_tree fixture_id"
      end

      oid = normalize_oid!(target_tree_oid)
      {fixture_id, oid}
    end)
  end

  defp normalize_oid!(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if Regex.match?(@oid_pattern, normalized) do
      normalized
    else
      raise ArgumentError, "invalid exact_target_tree oid"
    end
  end

  defp verify(request, targets, timeout_ms) do
    with {:ok, fixture_id} <- request_string(request, "fixture_id"),
         {:ok, workdir} <- request_string(request, "workdir"),
         {:ok, expected} <- Map.fetch(targets, fixture_id),
         true <- File.dir?(workdir),
         {:ok, actual} <- head_tree_oid(workdir, timeout_ms) do
      if actual == expected do
        :ok
      else
        {:error, :target_tree_mismatch}
      end
    else
      :error ->
        {:error, :unknown_fixture_target}

      false ->
        {:error, :invalid_workdir}

      {:error, reason} when is_atom(reason) or is_binary(reason) ->
        {:error, reason}

      _other ->
        {:error, :invalid_verifier_request}
    end
  end

  defp request_string(request, key) do
    case Map.get(request, key) do
      value when is_binary(value) and value != "" ->
        if String.valid?(value) and not String.contains?(value, <<0>>) do
          {:ok, value}
        else
          {:error, :invalid_verifier_request}
        end

      _other ->
        {:error, :invalid_verifier_request}
    end
  end

  defp head_tree_oid(workdir, timeout_ms) do
    case Git.run(workdir, ["rev-parse", "--verify", "HEAD^{tree}"], timeout_ms) do
      {:ok, output} ->
        oid = output |> String.trim() |> String.downcase()

        if Regex.match?(@oid_pattern, oid) do
          {:ok, oid}
        else
          {:error, :invalid_head_tree}
        end

      {:error, _reason} ->
        {:error, :head_tree_unavailable}
    end
  end
end
