# Trust tests manage their own trust processes via start_supervised!/start_link.
# Security stores are shared infrastructure: Arbor.Security.grant/1 needs the
# durable capability store since 206d06b5d ("make capability replacement
# durable", 2026-08-06). Without it every grant returns
# :capability_store_unavailable. Same bootstrap as the other consumer apps.
Arbor.Security.TestBootstrap.start!()

ExUnit.start(exclude: [:llm, :llm_local])
