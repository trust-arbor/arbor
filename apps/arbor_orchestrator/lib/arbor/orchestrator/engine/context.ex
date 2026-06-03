defmodule Arbor.Orchestrator.Engine.Context do
  @moduledoc false

  require Logger

  defmodule LineageEntry do
    @moduledoc """
    Structured record of a context mutation.

    Tracks both the fine-grained step time (when this node was executing)
    and the pipeline-level time (when the overall run began). This enables
    queries over "what changed during this node?" and "what was introduced
    in this pipeline execution?" even across resumes.
    """

    use TypedStruct

    typedstruct enforce: true do
      field(:node_id, String.t())
      field(:step_timestamp, DateTime.t())
      field(:pipeline_timestamp, DateTime.t() | nil)
      field(:operation, :set | :merge)
    end
  end

  @type lineage_entry :: LineageEntry.t()

  @type t :: %__MODULE__{
          values: map(),
          logs: [String.t()],
          lineage: map(),
          pipeline_started_at: DateTime.t() | nil
        }
  defstruct values: %{}, logs: [], lineage: %{}, pipeline_started_at: nil

  @doc """
  Construct a new context.

  Accepts an optional keyword list for purity:
  - `:pipeline_started_at` — the logical start time of the entire pipeline run.
    When provided, all subsequent lineage entries will carry this as
    `pipeline_timestamp`. This enables dual-clock tracking (pipeline vs step).
  """
  @spec new(map(), keyword()) :: t()
  def new(values \\ %{}, opts \\ [])

  def new(values, opts) when is_map(values) do
    pipeline_started_at = if is_list(opts), do: Keyword.get(opts, :pipeline_started_at), else: nil
    %__MODULE__{values: values, pipeline_started_at: pipeline_started_at}
  end

  @spec get(t(), String.t(), term()) :: term()
  def get(%__MODULE__{values: values}, key, default \\ nil), do: Map.get(values, key, default)

  @doc "Set a context value without tracking lineage."
  @spec set(t(), String.t(), term()) :: t()
  def set(%__MODULE__{values: values} = ctx, key, value) do
    check_value_budget(key, value, "anonymous")
    %{ctx | values: Map.put(values, key, value)}
  end

  @doc """
  Set a context value and record which node set it.

  Accepts an optional `step_now` timestamp for purity (the logical time of
  this node execution step). When omitted, the current time is used.

  The `pipeline_timestamp` is taken from the Context's `pipeline_started_at`
  if present, giving every lineage entry both clocks.
  """
  @spec set(t(), String.t(), term(), String.t(), DateTime.t() | nil) :: t()
  def set(
        %__MODULE__{values: values, lineage: lineage, pipeline_started_at: p_at} = ctx,
        key,
        value,
        node_id,
        step_now \\ nil
      )
      when is_binary(node_id) do
    step_ts = step_now || DateTime.utc_now()

    entry = %LineageEntry{
      node_id: node_id,
      step_timestamp: step_ts,
      pipeline_timestamp: p_at,
      operation: :set
    }

    new_values = Map.put(values, key, value)
    check_value_budget(key, value, node_id)
    check_size_budgets(new_values, node_id)

    %{ctx | values: new_values, lineage: Map.put(lineage, key, entry)}
  end

  @doc "Merge updates into context without tracking lineage."
  @spec apply_updates(t(), map()) :: t()
  def apply_updates(%__MODULE__{} = ctx, updates) when is_map(updates) do
    new_values = Map.merge(ctx.values, updates)
    check_updates_value_budgets(updates, "anonymous")
    check_size_budgets(new_values, "anonymous")
    %{ctx | values: new_values}
  end

  @doc """
  Merge updates into context and record which node set each key.

  Accepts an optional `step_now` timestamp for purity (the logical time of
  this node execution step). When omitted, the current time is used.

  The `pipeline_timestamp` is taken from the Context's `pipeline_started_at`
  if present.
  """
  @spec apply_updates(t(), map(), String.t(), DateTime.t() | nil) :: t()
  def apply_updates(
        %__MODULE__{values: values, lineage: lineage, pipeline_started_at: p_at} = ctx,
        updates,
        node_id,
        step_now \\ nil
      )
      when is_map(updates) and is_binary(node_id) do
    step_ts = step_now || DateTime.utc_now()

    new_lineage =
      updates
      |> Map.keys()
      |> Enum.reduce(lineage, fn key, acc ->
        entry = %LineageEntry{
          node_id: node_id,
          step_timestamp: step_ts,
          pipeline_timestamp: p_at,
          operation: :merge
        }

        Map.put(acc, key, entry)
      end)

    new_values = Map.merge(values, updates)
    check_updates_value_budgets(updates, node_id)
    check_size_budgets(new_values, node_id)

    %{ctx | values: new_values, lineage: new_lineage}
  end

  @doc """
  Returns the node_id that last set the given context key, or nil.

  Backward-compatible with three historical shapes:
  - bare string (very old)
  - plain map with :node_id
  - %LineageEntry{} struct (current)
  """
  @spec origin(t(), String.t()) :: String.t() | nil
  def origin(%__MODULE__{lineage: lineage}, key) do
    case Map.get(lineage, key) do
      %LineageEntry{node_id: node_id} -> node_id
      %{node_id: node_id} -> node_id
      node_id when is_binary(node_id) -> node_id
      nil -> nil
    end
  end

  @doc """
  Returns the full lineage entry for a context key, or nil.

  Returns either a %LineageEntry{} (preferred) or a legacy map for old data.
  """
  @spec lineage_entry(t(), String.t()) :: LineageEntry.t() | map() | nil
  def lineage_entry(%__MODULE__{lineage: lineage}, key), do: Map.get(lineage, key)

  @doc "Returns the full lineage map."
  @spec lineage(t()) :: map()
  def lineage(%__MODULE__{lineage: lineage}), do: lineage

  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{values: values}), do: values

  @doc "Returns the pipeline start time recorded on this context, if any."
  @spec pipeline_started_at(t()) :: DateTime.t() | nil
  def pipeline_started_at(%__MODULE__{pipeline_started_at: at}), do: at

  @doc "Returns the step timestamp from a lineage entry (handles struct or legacy map)."
  @spec step_timestamp(LineageEntry.t() | map()) :: DateTime.t() | nil
  def step_timestamp(%LineageEntry{step_timestamp: ts}), do: ts
  def step_timestamp(%{step_timestamp: ts}), do: ts
  # legacy field name
  def step_timestamp(%{timestamp: ts}), do: ts
  def step_timestamp(_), do: nil

  @doc "Returns the pipeline timestamp from a lineage entry (handles struct or legacy map)."
  @spec pipeline_timestamp(LineageEntry.t() | map()) :: DateTime.t() | nil
  def pipeline_timestamp(%LineageEntry{pipeline_timestamp: ts}), do: ts
  def pipeline_timestamp(%{pipeline_timestamp: ts}), do: ts
  def pipeline_timestamp(_), do: nil

  # ─────────────────────────────────────────────────────────────────
  # Context size budgets (runaway protection)
  # ─────────────────────────────────────────────────────────────────
  #
  # Phase 1: Logger.warning when budgets are exceeded — observability
  # first, no behavioral change. Phase 2 (enforcement: :error) flips
  # the warnings into an error path and is gated by
  # Arbor.Orchestrator.Config.context_budget_enforcement/0.

  defp check_value_budget(key, value, node_id) when is_binary(key) do
    case budgets_or_skip() do
      nil ->
        :ok

      budgets ->
        size = :erlang.external_size(value)

        if size > budgets.max_value_bytes do
          emit_budget_warning(:max_value_bytes, node_id, %{
            key: key,
            value_bytes: size,
            limit: budgets.max_value_bytes
          })
        end
    end
  end

  defp check_updates_value_budgets(updates, node_id) when is_map(updates) do
    case budgets_or_skip() do
      nil ->
        :ok

      budgets ->
        # Sample the value sizes — checking every entry is O(N * size).
        # For runaway protection a single huge value is the dominant
        # signal; we surface the largest one in the warning.
        Enum.each(updates, fn {key, value} ->
          size = :erlang.external_size(value)

          if size > budgets.max_value_bytes do
            emit_budget_warning(:max_value_bytes, node_id, %{
              key: key,
              value_bytes: size,
              limit: budgets.max_value_bytes
            })
          end
        end)
    end
  end

  defp check_size_budgets(values, node_id) when is_map(values) do
    case budgets_or_skip() do
      nil ->
        :ok

      budgets ->
        key_count = map_size(values)

        if key_count > budgets.max_keys do
          emit_budget_warning(:max_keys, node_id, %{
            key_count: key_count,
            limit: budgets.max_keys
          })
        end

        # max_total_bytes is the most expensive check (O(N) external_size
        # over the whole map). Only run it when we're already in
        # warning territory on key count, OR sample periodically.
        # For phase 1 we just do it when key_count is approaching the
        # budget to bound cost.
        if key_count > div(budgets.max_keys, 2) do
          total = :erlang.external_size(values)

          if total > budgets.max_total_bytes do
            emit_budget_warning(:max_total_bytes, node_id, %{
              total_bytes: total,
              limit: budgets.max_total_bytes
            })
          end
        end
    end
  end

  defp budgets_or_skip do
    # Runtime-resolved via Code.ensure_loaded? so Context stays usable
    # in isolated tests that don't start the full app.
    config = Arbor.Orchestrator.Config

    if Code.ensure_loaded?(config) and function_exported?(config, :context_budgets, 0) do
      config.context_budgets()
    else
      nil
    end
  end

  defp emit_budget_warning(kind, node_id, details) do
    Logger.warning(
      "[Context] node #{node_id}: budget #{kind} exceeded. " <>
        "Details: #{inspect(details)}. " <>
        "This is runaway-protection telemetry; the write was applied. " <>
        "Set `config :arbor_orchestrator, :context_budget_enforcement, :error` " <>
        "to fail instead of warn."
    )
  end
end
