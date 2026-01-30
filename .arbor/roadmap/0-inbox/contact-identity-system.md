# Contact Identity System

## Problem

**Current limitation:** When sending messages, you must use full identifiers:
- "Send email to kim@example.com"
- "Text +15559876543 on Signal"

**What we want:**
- "Send email to Kim" → resolves to kim@example.com
- "Text Kim" → resolves to Kim's Signal number
- "Send me an email" → resolves to owner's email

Comms channels identify the same person differently:
- Signal: `+15551234567`
- Limitless: `"pendant"`
- Email: `user@example.com`

Currently using a static `contact_aliases` map in config. This works for **authorization** (recognizing inbound identifiers) but not for **outbound resolution** (mapping names to identifiers for sending).

## Current State

We have `contact_aliases` for authorization:
```elixir
contact_aliases: %{"+15551234567" => ["pendant", "Hysun"]}
```

This lets MessageHandler recognize inbound messages from "+15551234567" as coming from "pendant" or "Hysun".

But it's **backwards** for outbound: we need to map `"Kim"` → `kim@example.com` or `"+15559876543"`.

## Design Options

### Option 1: Bidirectional Contact Map (Recommended)

Extend the config to support both directions:

```elixir
# In config/runtime.exs or .env
contacts: %{
  "hysun" => %{
    email: "hysun@example.com",
    signal: "+15551234567",
    aliases: ["pendant", "me", "owner"]
  },
  "kim" => %{
    email: "kim@example.com",
    signal: "+15559876543",
    aliases: []
  }
}
```

Implementation in Dispatcher:
```elixir
def send(channel, recipient, content, opts \\ []) do
  # Resolve friendly name → channel-specific identifier
  resolved = Config.resolve_contact(recipient, channel) || recipient
  # ... rest of send logic
end
```

**Pros:**
- Simple, immediate value
- Fits existing config patterns
- Contact info stays in .env (gitignored)
- ~50 lines of code
- Easy to implement today

**Cons:**
- Requires restart to update contacts
- No persistence beyond config files
- Limited to static config

### Option 2: Database-Backed Contact Store

Create `Arbor.Comms.Contacts` GenServer with persistence:

```elixir
Arbor.Comms.Contacts.add_contact("kim",
  email: "kim@example.com",
  signal: "+15559876543"
)
```

**Pros:**
- Runtime updates
- Persistent across restarts
- Can grow into full contact management
- Could support vCard import/export

**Cons:**
- More complex (needs persistence layer)
- Overkill for current needs

### Option 3: Hybrid - Config + Runtime

Start with config, allow runtime additions, save to file.

**Pros:**
- Best of both worlds
- Can evolve over time

**Cons:**
- Most complex to implement

## Recommendation

Start with **Option 1** because:
1. Solves the immediate problem simply
2. Extends existing `contact_aliases` concept
3. Security-friendly (contact info in .env)
4. Can evolve to Option 3 later

## Implementation Plan

1. **Add `Config.resolve_contact/2`**
   - Takes name/alias and channel
   - Returns channel-specific identifier or nil

2. **Update Dispatcher.send/4**
   - Resolve recipient before looking up channel module
   - Pass through if resolution fails (might be literal identifier)

3. **Update runtime.exs contact format**
   ```elixir
   contacts: %{
     "hysun" => %{email: email_to, signal: signal_to, aliases: ["me", "pendant"]},
     "kim" => %{email: "kim@example.com", signal: "+15559876543"}
   }
   ```

4. **Maintain backward compatibility**
   - If recipient looks like identifier (starts with "+", contains "@"), pass through
   - Only resolve if it looks like a name

5. **Tests**
   - Resolution by name, by alias, case-insensitive
   - Pass-through for literals
   - Missing contact handling

## Example Usage

```elixir
# After implementation:
Dispatcher.send(:email, "kim", "Hello!")        # → kim@example.com
Dispatcher.send(:signal, "hysun", "Test")       # → +15551234567
Dispatcher.send(:signal, "pendant", "Test")     # → +15551234567 (alias)
Dispatcher.send(:email, "me", "Note")           # → owner's email
```

## Future Enhancements

- Contact discovery: auto-link when same person uses multiple channels
- Contact groups: `"team" => ["kim", "alex", "jordan"]`
- Per-contact routing preferences (prefer email for long content)
- Trust/authorization levels
- vCard import/export
- Sync with external contact sources
- Privacy: opt-out of cross-channel linking
