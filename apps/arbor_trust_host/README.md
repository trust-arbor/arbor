# Arbor Trust product host

Passive composition for canonical active `:arbor_trust`. KernelRuntime and the
Security product composition precede Trust. This application has no callback,
registered authority tree or replacement PolicyHost. Its static RuntimeHost
uses the existing KernelRuntime provider gate and roots; its public Signals
adapters preserve trust invalidation and observation semantics.

Root product configuration selects every provider, the historical SQL profile
backend/options/collection/name and `Arbor.Core.PubSub` explicitly. Authority
roles remain `:arbor_trust` with the existing Supervisor/ConfirmationTracker and
Supervisor/CapabilityGrantOwner paths. Product integration suites remain active
in this application; Core owns all policy and persistence mechanisms.
