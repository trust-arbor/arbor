# Contact Identity System

## Problem

Comms channels identify the same person differently:
- Signal: `+15551234567`
- Limitless: `"pendant"`
- Email: `user@example.com`

Currently using a static `contact_aliases` map in config. This works for a single user but won't scale to multiple contacts or dynamic discovery.

## What's Needed

A contact card / identity DB that maps:
- Multiple channel identifiers → single contact identity
- Contact metadata (name, preferences, timezone)
- Per-contact routing preferences (prefer email for long content, signal for quick)
- Trust/authorization level per contact

## Current Workaround

`config :arbor_comms, :handler, contact_aliases: %{"+15551234567" => ["pendant"]}` — static map in config.exs.

## Future Considerations

- Could live in `arbor_persistence` as a simple ETS/DETS store
- Or a proper Ecto schema if we already have Postgres
- Contact discovery: auto-link identities when the same person messages from multiple channels
- Privacy: contacts should be able to opt out of cross-channel linking
