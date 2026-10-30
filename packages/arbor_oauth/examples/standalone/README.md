# Standalone OAuth consumer

This fixture consumes only `arbor_oauth` and public dependencies. The package
is passive. Its bundled Req transport is activated explicitly: the consumer
starts the provider applications and supervises the public
`Arbor.Common.OAuth.HttpClient.Pool` child specification. The release lists
those provider applications as `:load`, so its first probe can prove that
loading OAuth alone does not start an HTTP pool.

`OAuthStandaloneConsumer.verify!/1` exercises the real authorization-code,
device-code, polling and refresh APIs over owned ephemeral loopback HTTP
listeners. It also checks transport bounds, no redirects/retries, credential
redaction, configuration priority and pool stop/restart behavior. Results
contain check names and counts; token, request-form and response-body values
are never returned in the report.

The package qualification script builds an actual Hex archive, checks its
members and metadata, compiles this consumer from the unpacked archive with
fresh dependency builds, then runs an ERTS release after hiding only the
qualification's copied source and tool directories. It never publishes,
fetches dependencies, renames a live checkout or changes operator homes.

Use `packages/arbor_oauth/scripts/qualify_standalone.py --help` for pinned
tool, source-cache and guarded Main/candidate inputs. Run only from an isolated
worktree with a fresh private evidence directory.
