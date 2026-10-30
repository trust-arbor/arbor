# Capabilities adoption verification snapshot

The retained owning and integration suite receipts passed. This snapshot binds the pre-style staged tree `6099987466004527b245acf2ecfae65673abaa2f`; later evidence must bind its own source tree. The remaining CLI failures must be
reported accurately: source-coupling still fails its historical baseline,
xref remains over its existing limit, the unused-lock list is unchanged, and
root quality stops at an unchanged Dashboard formatting defect. This snapshot
does not credit cold qualification or Grok review and does not declare product
release completion.

The comparison uses the actual predecessor
`3fbe6596fa2da06480fbdd75c3b516815d79a9d3`, not a regenerated baseline.
The retained [predecessor report](../../tmp/verification/capabilities-adoption-20261030/source-coupling-base-01/source-coupling-base-01.log)
and [candidate report](../../tmp/verification/capabilities-adoption-20261030/source-coupling-final-01/source-coupling-final-01.log)
both report Git-index blob provenance and `errors: []`.
[The structured comparison](../../tmp/verification/capabilities-adoption-20261030/structuredsource-coupling-comparison.json) binds
their hashes, preserves every additional/removed diagnostic, and maps its cause.

The results below belong to the retained verification snapshots. Subsequent
scoped alias and implicit-try style cleanup does not itself rerun or recredit
those checks; final staged verification and normal hooks remain separately
accounted for by Root. Source-file hashes in the companion record bind the
comparison snapshot, not an unmeasured later tree.

## Source-coupling comparison

| Metric | Actual predecessor | Candidate |
| --- | ---: | ---: |
| Application owners | 32 | 34 |
| Production source files | 2,047 | 2,052 |
| Tracked census files | 2,079 | 2,086 |
| Application pairs | 222 | 221 |
| Undeclared application pairs | 54 | 49 |
| Total occurrences | 9,818 | 9,848 |
| Declared occurrences | 5,060 | 6,086 |
| Undeclared occurrences | 4,758 | 3,762 |
| Code occurrences | 8,825 | 8,855 |
| Typespec-only occurrences | 993 | 993 |
| Upward band occurrences | 25 | 23 |
| Upward longest-path hierarchy occurrences | 59 | 56 |
| Reported unresolved count | 8 | 8 |
| Historical-baseline failures | 166 | 422 |

The failure-object difference is **260 additional and four removed**, all
mapped in the JSON companion:

- 255 additional `baseline_entry_removed` diagnostics use former
  `apps/arbor_security/lib/` paths. Their source exists under its canonical
  Core or Signals-adapter package owner.
- Three additional removals are existing Memory-to-Security findings that
  now have Memory's direct canonical Core dependency.
- Two additional `occurrence_metadata_changed` diagnostics are the existing
  LLM Config and StockToolTransport `Module.concat` references to
  `Arbor.Security`. Their source bytes are unchanged; the actual target owner
  is now `arbor_capabilities`.
- Four prior Security occurrence-count drift diagnostics no longer apply to
  their old undeclared Host-path keys after the move to a directly declared
  package owner. Their source and historical diagnostic are retained in the
  comparison.

The same **18 `new_finding` rows** remain relative to the old frozen baseline;
none was introduced by this adoption. Their six source files are unchanged
from the actual predecessor. The unresolved records are identical.

No genuinely new logical undeclared edge was observed. The only added
physical undeclared pair is `arbor_llm -> arbor_capabilities`, carrying the
same two references formerly recorded as `arbor_llm -> arbor_security`.
Every surviving pair keeps its occurrence count. The 996-occurrence reduction
is accounted for exactly: 984 old Security-to-Kernel references are now
declared by Core, nine Memory-to-Security references are now declared against
Core, and the three implicit Comms/Consensus/Historian defaults were removed
from Core. Root config explicitly retains those product composition choices.

The new declared physical composition is Host-to-Core (`P -> P`) and the
Signals adapter's dependencies on Core (`P -> P`) and Signals (`P -> K`).
Host-to-KernelRuntime is retained, with KernelRuntime preceding required Core
startup. Core declares no reverse dependency on Host or KernelRuntime.
These findings explain the migration-sensitive baseline failure; they do not
turn `source_coupling --check` into a pass or authorize rewriting its history.

## Other CLI checks

App-env inventory is clean: production, test support, config block, untrusted,
and total counts are all zero.

Xref reports 92 compile-connected references against the unchanged limit of
88; the actual predecessor reports 93. No compile edge was added. The graph
loses the Gateway terminal-login compile edge. Both checks remain failed.

The unused-dependency check fails with the same 42 names. Its predecessor
and candidate logs are byte-identical. This adoption does not add lock debt.

Root `quality` stops at the existing span formatting in
`apps/arbor_dashboard/lib/arbor_dashboard/live/agents_live.ex`: the multiline
closing span must format as `></span>`. That file is byte-identical to the
predecessor. This is separate from the formatted adoption source set and is
not reported as a successful whole-root quality run. Expanded Credo and
normal-hook results must be accounted for separately when available.

## Completed owning and integration verification

The following completed results are reported by Root and retained in the
existing lane receipts:

| Lane | Result |
| --- | --- |
| Core owning suite | 2,096 tests, zero failures |
| Product Security Host | 74 tests, zero failures |
| Trust | 706 tests and one property, zero failures |
| KernelRuntime | 1,757 tests and eight doctests, zero failures |
| Commands integration | 102 tests, zero failures |
| Policy hierarchy | 47 tests, zero failures |
| Signals adapter | Strict compile and three tests passed |
| Construction | Eight packages passed |
| Root strict compile | Passed |

These results are not substitutes for the separately recorded cold qualification,
review, and release gates. This snapshot makes no claim that cold qualification
or Grok has passed.

## Separate runtime M2 gap

The existing `docs/arbor/CAPABILITIES_M2_COUPLING_GAP.md` files a different
gap: frozen v1 recovery policy still selects the historical four applications
and names the former authority owner. Canonical Core is therefore unexpected
first-party under v1, and actual Core-owned modules leave runtime closure
open. V1 architecture status remains blocked. A historical closed snapshot
does not attest a current live monitor.

That deliberate fail-closed runtime result must not be conflated with static
source-baseline drift or preexisting quality debt. A reviewed versioned
successor must bind current responsibilities and actual authority provenance;
the old schemas, receipts, and baseline remain unchanged. Core adoption is
not product release completion.

## Rename-aware lint comparison

The expanded comparison includes all 547 changed Elixir paths, including 291
rename destinations, against 513 existing predecessor paths. The predecessor
has 941 diagnostics. After removing the 21 new style diagnostics, the candidate
has 959: 938 match exactly after path normalization, 17 are inherited or newly
exposed by removal of ambiguous aliases and test relocation, and four flag
bounded names generated by private peer fixtures. Those four expressions take
no request input, execute a bounded fixture sequence, and are excluded from
published package contents. They remain visible with explanatory comments;
no security check is disabled. No new production security-check diagnostic was
observed. These lint results bind the retained post-style receipt, separately
from the earlier static-census snapshot above.
