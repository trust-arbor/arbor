defmodule Arbor.Common.TemporalGrouping do
  @moduledoc """
  Temporal bucketing and formatting for memory items in prompts.

  Groups items by time buckets (Today/Yesterday/This Week/Earlier/Upcoming)
  and formats them with time annotations, giving agents temporal awareness
  of their own memories.

  ## Bucket Classification

  - `:upcoming` — referenced_date in the future
  - `:today` — same date as now
  - `:yesterday` — 1 day ago
  - `:this_week` — 2-6 days ago
  - `:earlier` — 7+ days ago

  Uses `Date.compare/2` (not struct comparison) to avoid the Elixir gotcha
  where `>=`/`<=` use structural ordering on Date/DateTime structs.
  """

  alias Arbor.Common.Time

  @bucket_order [:upcoming, :today, :yesterday, :this_week, :earlier]

  @bucket_headers %{
    upcoming: "### Upcoming",
    today: "### Today",
    yesterday: "### Yesterday",
    this_week: "### This Week",
    earlier: "### Earlier"
  }

  @doc """
  Classify a datetime into a temporal bucket relative to `now`.

  Returns one of: `:upcoming`, `:today`, `:yesterday`, `:this_week`, `:earlier`.

  Uses `Date.diff/2` for correct semantic comparison.
  """
  @spec classify_bucket(DateTime.t() | Date.t() | nil, DateTime.t()) :: atom()
  def classify_bucket(nil, _now), do: :today

  def classify_bucket(dt, now) do
    target_date = to_date(dt)
    now_date = to_date(now)
    diff = Date.diff(now_date, target_date)

    cond do
      diff < 0 -> :upcoming
      diff == 0 -> :today
      diff == 1 -> :yesterday
      diff <= 6 -> :this_week
      true -> :earlier
    end
  end

  @doc """
  Group items into ordered temporal buckets.

  `extract_date_fn` receives each item and returns
  `{observation_datetime, referenced_datetime | nil}`.

  Bucket is determined by `referenced_date` when non-nil, otherwise
  by `observation_datetime`.

  Returns a keyword list `[upcoming: [...], today: [...], ...]` with
  items within each bucket sorted newest-first. Empty buckets are omitted.

  ## Options

  - `:now` — override current time (default: `DateTime.utc_now()`)
  """
  @spec group_by_time(
          list(),
          (any() -> {DateTime.t() | nil, DateTime.t() | Date.t() | nil}),
          keyword()
        ) :: keyword()
  def group_by_time(items, extract_date_fn, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    grouped =
      items
      |> Enum.group_by(fn item ->
        {obs_dt, ref_dt} = extract_date_fn.(item)
        classify_bucket(ref_dt || obs_dt, now)
      end)

    @bucket_order
    |> Enum.flat_map(fn bucket ->
      case Map.get(grouped, bucket) do
        nil ->
          []

        [] ->
          []

        items_in_bucket ->
          sorted =
            Enum.sort_by(
              items_in_bucket,
              fn item ->
                {obs_dt, _ref_dt} = extract_date_fn.(item)
                obs_dt || now
              end,
              {:desc, DateTime}
            )

          [{bucket, sorted}]
      end
    end)
  end

  @doc """
  Render grouped items as prompt text with temporal headers.

  `format_item_fn` receives `{item, annotation}` where annotation is a
  time string like `[14:30]` or `[Feb 18 14:30]`.

  Empty buckets are omitted. Returns the full formatted text.

  ## Options

  - `:now` — override current time (default: `DateTime.utc_now()`)
  """
  @spec format_grouped(
          keyword(),
          (any() -> {DateTime.t() | nil, DateTime.t() | Date.t() | nil}),
          (any(), String.t() -> String.t()),
          keyword()
        ) :: String.t()
  def format_grouped(grouped, extract_date_fn, format_item_fn, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    Enum.map_join(grouped, "\n\n", fn {bucket, items} ->
      header = Map.get(@bucket_headers, bucket, "### #{bucket}")

      lines =
        Enum.map_join(items, "\n", fn item ->
          {obs_dt, ref_dt} = extract_date_fn.(item)
          annotation = time_annotation(obs_dt, ref_dt, now)
          format_item_fn.(item, annotation)
        end)

      "#{header}\n#{lines}"
    end)
  end

  @doc """
  Produce a time annotation string for use in prompts.

  - Today: `[HH:MM]`
  - Other days: `[Feb 18 14:30]`
  - With referenced_date different from observation date: appends ` (refers to Feb 19)`
  """
  @spec time_annotation(DateTime.t() | nil, DateTime.t() | Date.t() | nil, DateTime.t()) ::
          String.t()
  def time_annotation(nil, nil, _now), do: ""
  def time_annotation(nil, ref_dt, _now), do: "(refers to #{Time.month_day(ref_dt)})"

  def time_annotation(obs_dt, nil, now) do
    Time.prompt_annotation(obs_dt, now)
  end

  def time_annotation(obs_dt, ref_dt, now) do
    base = Time.prompt_annotation(obs_dt, now)
    obs_date = to_date(obs_dt)
    ref_date = to_date(ref_dt)

    if Date.compare(obs_date, ref_date) != :eq do
      "#{base} (refers to #{Time.month_day(ref_dt)})"
    else
      base
    end
  end

  # Convert DateTime or Date to Date for comparison
  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%Date{} = d), do: d
  defp to_date(_), do: Date.utc_today()
end
