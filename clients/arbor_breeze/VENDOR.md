# Terminal dependency sources

The Breeze client includes reviewed source copies of Breeze and Termite so a
normal build can use the required input and cleanup fixes. These dependencies
belong to this renderer; ConversationKit, its Arbor adapters, and the client SDK
do not depend on them. Both copies retain Gary Rennie's MIT license in their
respective `LICENCE.md` files.

The source copies start with the published Breeze 0.5.3 and Termite 0.4.5 Hex
distributions. Local preparation revisions identify the exact reviewed trees:

| Dependency | Local preparation revision | Included files |
| --- | --- | --- |
| Breeze | `0252cf5744df47fb19681cd3d559abedb30542dd` | 104 |
| Termite | `5aede272e127e31115c9b8fd4373a40d95e576b5` | 18 |

These revision IDs describe local Hex imports and patch preparation, not
upstream Git history or published forks. Breeze's minimal ExUnit test helper was
added separately from its imported distribution. The upstream project URLs
remain in each dependency's README and Mix project.

The copies omit only the two packages' `.hex` and `hex_metadata.config` transport
metadata and Termite's shipped `.expert/expert.log` editor log. All included
source, tests, Mix projects, and licenses retain the reviewed bytes.

The Breeze changes add bounded bracketed-paste parsing, preserve literal Unicode
and multiline edits, route paste to the focused editor, and restore terminal
resources through their actual owner. A paste delimiter split across slow input
chunks cannot become an implicit Enter. Expired framing is discarded until its
closing marker; a subsequent complete paste requires an explicit Enter to send.
The parser's hard byte limit and configurable timing bounds remain distinct.

The Termite change stops and monitors its exact owned Shell.Reader. Normal owner
exit must not leave a reader blocked in `IO.getn`. Borrowed terminal adapters are
not stopped. Shared-shell cooked-mode restoration while the VM remains alive is
outside this cleanup claim.

## Building and maintaining the copies

`mix.exs` uses `vendor/breeze` and an explicit `vendor/termite` override. Mix does
not lock path dependencies; the repository owns their source versions. The
remaining Hex dependency records stay in `mix.lock`. Normal dependency resolution
and compilation require no patching of a fetched dependency cache.

Retain the source, licenses, and regression tests together when updating either
copy. Run the client tests and dependency regression tests, then exercise actual
raw terminal input, resize, and normal/failure teardown. Decoded component events
alone cannot establish the terminal parser's behavior. Browser/terminal command
and cancellation acceptance remains a separate application check.

When an upstream release includes the required fixes, replace these two path
declarations and regenerate only the relevant lock records through Mix. Review
the source and run the same acceptance cases before removing the copies. No
upstream contribution or fork publication is implied by including them here.
