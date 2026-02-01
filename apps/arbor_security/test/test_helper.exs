# Add children to the empty app supervisor (start_children: false leaves it empty)
for child <- [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.CapabilityStore, []}
    ] do
  Supervisor.start_child(Arbor.Security.Supervisor, child)
end

ExUnit.start()
