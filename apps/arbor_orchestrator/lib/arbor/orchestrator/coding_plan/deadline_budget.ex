defmodule Arbor.Orchestrator.CodingPlan.DeadlineBudget do
  @moduledoc """
  Pure deadline-budget calculations for bounded coding operations.

  A request without budget metadata follows the legacy path unchanged. When
  metadata is supplied, the requested timeout is capped by the remaining
  deadline after reserving time for completion.
  """

  @binding_attrs ~w(
    timeout_budget.deadline_key
    timeout_budget.cap_key
    timeout_budget.reserve_key
  )
  @binding_param_attr "timeout_budget.param"
  @default_binding_param "timeout"
  @action_param_name ~r/\A[a-z][a-z0-9_]*\z/

  @type timeout_ms :: pos_integer()
  @type deadline_unix_ms :: pos_integer() | nil
  @type completion_reserve_ms :: non_neg_integer() | nil
  @type now_unix_ms :: integer()
  @type result :: {:ok, timeout_ms()} | {:error, :budget_exhausted | :invalid_budget_metadata}
  @type binding_result ::
          {:ok, String.t() | nil}
          | {:error, :invalid_timeout_budget_attrs | :invalid_timeout_budget_metadata}

  @doc """
  Returns the action parameter supplied or constrained by a timeout-budget binding.

  The three source attributes are all-or-none. A complete binding defaults to
  the `timeout` action parameter; an entirely absent binding returns `nil`.
  """
  @spec binding_parameter(map()) :: binding_result()
  def binding_parameter(attrs) when is_map(attrs) do
    bindings = Enum.map(@binding_attrs, &Map.get(attrs, &1))

    cond do
      Enum.all?(bindings, &is_nil/1) and is_nil(Map.get(attrs, @binding_param_attr)) ->
        {:ok, nil}

      Enum.all?(bindings, &(is_binary(&1) and &1 != "")) ->
        param_name = Map.get(attrs, @binding_param_attr, @default_binding_param)

        if valid_action_param_name?(param_name) do
          {:ok, param_name}
        else
          {:error, :invalid_timeout_budget_metadata}
        end

      true ->
        {:error, :invalid_timeout_budget_attrs}
    end
  end

  def binding_parameter(_attrs), do: {:error, :invalid_timeout_budget_attrs}

  @spec cap(timeout_ms(), deadline_unix_ms(), completion_reserve_ms(), now_unix_ms()) :: result()
  def cap(requested_timeout_ms, nil, nil, _now_unix_ms)
      when is_integer(requested_timeout_ms) and requested_timeout_ms > 0 do
    {:ok, requested_timeout_ms}
  end

  def cap(requested_timeout_ms, run_deadline_unix_ms, completion_reserve_ms, now_unix_ms)
      when is_integer(requested_timeout_ms) and requested_timeout_ms > 0 and
             is_integer(run_deadline_unix_ms) and run_deadline_unix_ms > 0 and
             is_integer(completion_reserve_ms) and completion_reserve_ms >= 0 and
             is_integer(now_unix_ms) do
    remaining_ms = run_deadline_unix_ms - now_unix_ms - completion_reserve_ms

    if remaining_ms <= 0 do
      {:error, :budget_exhausted}
    else
      {:ok, min(requested_timeout_ms, remaining_ms)}
    end
  end

  def cap(_requested_timeout_ms, _run_deadline_unix_ms, _completion_reserve_ms, _now_unix_ms),
    do: {:error, :invalid_budget_metadata}

  defp valid_action_param_name?(name) when is_binary(name) and byte_size(name) <= 64,
    do: Regex.match?(@action_param_name, name)

  defp valid_action_param_name?(_name), do: false
end
