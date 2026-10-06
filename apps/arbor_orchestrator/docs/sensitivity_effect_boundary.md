# Sensitive compute admission at the model effect

A non-public compute context requires a successful sensitivity decision for every
actual provider/model attempt. Initial routing may select a safer candidate;
that selection does not authorize later availability fallback, Dispatcher retry,
ToolLoop retry, native runtime selection or a model changed by Client middleware.
Policy absence, failure, malformed output or a second reroute at the effect
boundary refuses the current attempt. Public/unclassified contexts retain their
existing behavior. Session turn-egress, Trust egress and tool capability checks
remain separate required gates.

`Arbor.Orchestrator.Config.sensitivity_routing_module/0` resolves the trusted
policy facade (default `Arbor.AI`). The owning compute captures its sensitivity,
principal, selected client and policy module. Both initial selection and final
admission use that facade. A policy module change during the decision refuses.

The Client resolves its transport before invoking complete/stream middleware.
Appending another middleware can examine the final model, but cannot attest the
already selected transport when an earlier middleware changes provider identity.
Moreover, `complete_streaming/4` and its single-attempt form intentionally invoke
the adapter without middleware. `Client.adapter_for/2` is a public read-only
lookup; by itself it does not place a gate on these later effects.

For these concrete gaps, `LlmRouting.Sensitivity` wraps only the sensitive
compute's client in an owner-bound adapter. Its first middleware records the
provider used for transport selection. Immediately before calling the original
adapter, it rejects a changed provider identity and admits the post-middleware
model. Streaming APIs without middleware use their immutable selection input.
Each fallback reaches the same boundary independently; no initial permission is
reused. The private scope crosses the Client-owned deadline worker and is removed
before transport options are sent to the original adapter. Known implicit Client
catalog routes are included through `Arbor.LLM.known_providers/0`, which discovers
neither credentials nor live availability.

Native runtimes use the existing source-owned exact-route callback. Sensitivity
is composed after the existing Session/Trust callback; a malformed present
callback is refused. The supported Dispatcher invokes it before each primary or
fallback runtime preparation/effect. A custom Dispatcher must honor that same
contract and the supplied Client.

This is additional compute admission, not a general provider wrapper or runtime
mode. ReqLLM's Plug pipeline remains the mechanism for cross-cutting provider
concerns. A ReqLLM plug alone cannot protect OAuth/custom Client adapters, native
runtimes, or the ToolLoop's Client calls. The lower Client retains its general
purpose behavior, and tool definitions never confer action authority.
