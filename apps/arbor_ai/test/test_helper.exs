# Add children to the empty app supervisor (start_children: false leaves it empty)
children =
  [
    Arbor.AI.QuotaTracker
  ] ++
    if(Application.get_env(:arbor_ai, :enable_budget_tracking, true),
      do: [Arbor.AI.BudgetTracker],
      else: []
    ) ++
    if(Application.get_env(:arbor_ai, :enable_stats_tracking, true),
      do: [Arbor.AI.UsageStats],
      else: []
    )

for child <- children do
  Supervisor.start_child(Arbor.AI.Supervisor, child)
end

ExUnit.start(exclude: [:external, :skip, :llm, :llm_local])
