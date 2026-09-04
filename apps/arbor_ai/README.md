# Arbor AI

Unified LLM and ACP facade for Arbor (`Arbor.AI`). Routes text generation,
embeddings, provider readiness, budgets, and Agent Client Protocol sessions
through one library so CLI and API providers share the same call path.

```elixir
{:ok, result} = Arbor.AI.generate_text("What is 2+2?")
result.text

{:ok, result} = Arbor.AI.generate_text("Hello", provider: :anthropic)
```

Defaults live under `:arbor_ai`. API keys come from the environment
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and provider-specific OAuth via
`Arbor.LLM.OAuth`). Cross-cutting LLM concerns (telemetry, retry, cost)
belong in the `Arbor.LLM.Plug` pipeline, not as flags on this facade.

This is an umbrella app (L4). It depends on `arbor_llm`, `arbor_security`,
`arbor_shell`, and `arbor_kernel_runtime`. Higher apps (`arbor_orchestrator`,
`arbor_agent`) call this facade rather than provider internals.

## License

MIT
