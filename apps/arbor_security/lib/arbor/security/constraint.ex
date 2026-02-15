defmodule Arbor.Security.Constraint do
  @moduledoc """
  Evaluates capability constraints against runtime context.

  Dispatches by constraint key, evaluating stateless constraints first
  (time_window, allowed_paths) before stateful ones (rate_limit). If a
  stateless constraint rejects, no rate limit tokens are consumed.

  Unknown constraint keys are ignored for forward compatibility.
  """

  alias Arbor.Security.Constraint.RateLimiter

  @doc """
  Enforce all constraints in the given map.

  Returns `:ok` if all constraints pass, or `{:error, {:constraint_violated, type, context}}`
  for the first constraint that fails.

  Evaluation order (stateless first, stateful last):
  1. `time_window` — is the current hour within the allowed window?
  2. `allowed_paths` — does the resource URI match an allowed path pattern?
  3. `rate_limit` — consume a token from the rate limiter
  4. `requires_approval` — always `:ok` (Phase 5 placeholder)
  """
  @spec enforce(map(), String.t(), String.t()) ::
          :ok | {:error, {:constraint_violated, atom(), map()}}
  def enforce(constraints, _principal_id, _resource_uri) when constraints == %{}, do: :ok

  def enforce(constraints, principal_id, resource_uri) do
    with :ok <- evaluate_time_window(constraints[:time_window]),
         :ok <- evaluate_allowed_paths(constraints[:allowed_paths], resource_uri),
         :ok <- evaluate_rate_limit(constraints[:rate_limit], principal_id, resource_uri) do
      # Phase 5 placeholder — requires_approval is recognized but always passes
      evaluate_requires_approval(constraints[:requires_approval])
    end
  end

  # ===========================================================================
  # Individual constraint evaluators
  # ===========================================================================

  @doc false
  @spec evaluate_time_window(map() | nil) ::
          :ok | {:error, {:constraint_violated, :time_window, map()}}
  def evaluate_time_window(nil), do: :ok

  def evaluate_time_window(%{start_hour: start_hour, end_hour: end_hour}) do
    current_hour = DateTime.utc_now().hour

    in_window? =
      if start_hour <= end_hour do
        current_hour >= start_hour and current_hour < end_hour
      else
        # Wraps midnight, e.g. start: 22, end: 6
        current_hour >= start_hour or current_hour < end_hour
      end

    if in_window? do
      :ok
    else
      {:error,
       {:constraint_violated, :time_window,
        %{current_hour: current_hour, start_hour: start_hour, end_hour: end_hour}}}
    end
  end

  @doc false
  @spec evaluate_allowed_paths(list(String.t()) | nil, String.t()) ::
          :ok | {:error, {:constraint_violated, :allowed_paths, map()}}
  def evaluate_allowed_paths(nil, _resource_uri), do: :ok

  def evaluate_allowed_paths(paths, resource_uri) when is_list(paths) do
    if Enum.any?(paths, fn path -> path_matches?(resource_uri, path) end) do
      :ok
    else
      {:error,
       {:constraint_violated, :allowed_paths, %{resource_uri: resource_uri, allowed_paths: paths}}}
    end
  end

  # Exact match or prefix with "/" separator — prevents "/home" matching "/home_config"
  defp path_matches?(resource_uri, allowed_path) do
    resource_uri == allowed_path or
      String.starts_with?(resource_uri, allowed_path <> "/")
  end

  @doc false
  @spec evaluate_rate_limit(pos_integer() | nil, String.t(), String.t()) ::
          :ok | {:error, {:constraint_violated, :rate_limit, map()}}
  def evaluate_rate_limit(nil, _principal_id, _resource_uri), do: :ok

  def evaluate_rate_limit(max_tokens, principal_id, resource_uri)
      when is_integer(max_tokens) and max_tokens > 0 do
    case RateLimiter.consume(principal_id, resource_uri, max_tokens) do
      :ok ->
        :ok

      {:error, :rate_limited} ->
        remaining = RateLimiter.remaining(principal_id, resource_uri, max_tokens)

        {:error, {:constraint_violated, :rate_limit, %{limit: max_tokens, remaining: remaining}}}
    end
  end

  @doc false
  # requires_approval is recognized but always passes here — the actual
  # approval check is handled by Escalation.maybe_escalate/3 which runs
  # after constraint enforcement in the authorization pipeline.
  @spec evaluate_requires_approval(boolean() | nil) :: :ok
  def evaluate_requires_approval(_), do: :ok
end
