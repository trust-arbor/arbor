# Arbor Custody

Caller-owned custody and exact supervised-process provenance for Elixir/OTP.
The package has no first-party or third-party dependencies. Its only additional
OTP application is `:crypto`. Starting it creates no custody processes or stores.

Use the `Arbor.Custody` facade for:

- Authenticated calls to exact local server PIDs, backed by private ETS challenge
  custody and VM-observed proof-table ownership.
- Process-private state slots whose sealed table cannot be substituted through
  ordinary GenServer callback state.
- Exact registered-child lookup and startup application-root provenance.

```elixir
# Inside the owning server:
custody = Arbor.Custody.new_authenticated_call_custody()

# Inside its handle_info/2 callback:
case Arbor.Custody.handle_authenticated_call(message, custody) do
  {:authenticated, caller, request, reply_to} ->
    # Apply the application's own authorization policy to caller and request.
    Arbor.Custody.reply_authenticated_call(reply_to, {:ok, caller, request})

  _pending_or_rejected ->
    :ok
end

# Inside the caller, after independently verifying server_pid:
Arbor.Custody.authenticated_call(server_pid, :request)
```

Authentication establishes the calling process, not its application permissions.
A registered name alone does not authenticate the server. Long-lived authority
owners must be sensitive from startup; the temporary sensitive flag around one
authenticated call does not protect messages delivered at other times. Custody
operations run synchronously in their caller. The bounded registered-child lookup
retains its existing supervised lookup task.

The original Common compatibility entry points and this facade intentionally
share the existing Common protocol, sealed-table keys, ETS table names and call
error identities. Values created before adoption remain visible to the same
owning process after adoption. The fixed legacy identity atoms are compatibility
values, not dependencies on Kernel Runtime. Signals retains its separate helper
and custody identity in this first extraction.

This package supplies no signing-authority broker, taint policy, application
authorization, distributed protocol or process lifecycle ownership. Those remain
the responsibility of consuming libraries.
