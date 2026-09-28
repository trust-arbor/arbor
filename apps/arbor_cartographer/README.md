# Arbor Cartographer

Hardware capability-aware scheduling for distributed Arbor agents
(`Arbor.Cartographer`). Nodes advertise CPU, memory, GPU, and custom
tags; callers ask for a capable node and deploy to it.

```elixir
{:ok, _} = Arbor.Cartographer.start_link()

{:ok, nodes} = Arbor.Cartographer.find_capable_nodes([:gpu])

{:ok, pid} = Arbor.Cartographer.deploy(MyLLMAgent,
  needs: [:gpu, :high_memory],
  args: [model: "llama-3-70b"]
)
```

Current implementation is local-only (hardware detection, capability
registration, load monitoring). Cluster routing via eigr/mesh is planned,
not wired. See `Arbor.Contracts.Libraries.Cartographer` for the API
contract.

This is an umbrella app (L1) with a single in-umbrella dependency:
`arbor_kernel`.

## License

MIT
