# In-VM `Code.eval*` / `Code.compile*` inventory

**Date:** 2026-10-15
**Verified against:** `origin/main` `56e45390b`, then this change.
**Method:** AST walk of git-tracked Elixir (not grep). `Code.string_to_quoted/2`
only parses and is not a loader. Comments, `@moduledoc`, and heredoc-emitted
source that *mentions* `Code.compile_string` do not count.

A production-lib drift guard lives at
`apps/arbor_kernel/test/arbor/contracts/code_loader_sites_lint_test.exs`.
`apps/arbor_actions` also keeps a library-local allowlist in
`apps/arbor_actions/test/arbor/actions/security/code_compile_sites_lint_test.exs`.

Untrusted-input rule: LLM output, HTTP/network bodies, dashboard users, and
agent-provided files must not reach `Code.eval_string/eval_quoted/eval_file`
or `Code.compile_string/compile_quoted/compile_file` in the host VM.
Prefer removal, `Code.string_to_quoted` + an allowlisted AST, or
`Arbor.Sandbox.authorize_eval/4` (Dune). If removing a site would break a
feature and the right replacement is unclear, gate it and flag it below
rather than deleting.

---

## Production `apps/*/lib` loader sites

| File:line | Call | Purpose | Untrusted input? | Disposition |
| --- | --- | --- | --- | --- |
| `apps/arbor_gateway/lib/arbor/gateway/dev/router.ex` (was :146) | `Code.eval_string` | `POST /api/dev/eval` evaluated the JSON `code` field | **Yes** — HTTP body (network), even on localhost | **Removed 2026-10-15.** Route remains and returns 403. Regression: `dev_eval_security_regression_test.exs`. |
| `apps/arbor_actions/lib/arbor/actions/code.ex:593` | `Code.compile_string` | `Arbor.Actions.Code.HotLoad` compiles one authorized module after `Arbor.Sandbox.Code.validate(ast, :hot_load)` | Agent-supplied `source` (capability + trust + sandbox AST gate first) | **Keep.** Intentional hot-load. F-007 regressions in `code_hot_load_module_binding_security_regression_test.exs`. |
| `apps/arbor_actions/lib/arbor/actions/security/synthesize_detector.ex:211` | `Code.compile_string` | G1 self-check compiles `DetectorTemplate` output for a coerced `%DetectorSpec{}` | Spec fields from synthesis (LLM JSON coerced through an allowlist; values interpolated via `inspect/1`) | **Keep.** Never compiles caller text. |
| `apps/arbor_actions/lib/arbor/actions/security/sweep_candidate.ex:312` | `Code.compile_string` | Compiles regenerated `DetectorTemplate` source from a validated spec | Caller `module_source` is compared, never compiled (F-008) | **Keep.** Provenance regressions in `sweep_candidate_provenance_security_regression_test.exs`. |
| `apps/arbor_kernel_runtime/lib/mix/tasks/arbor/eval.ex:43` | `:rpc.call(Code, :eval_string)` (`:rpc.call(node, Code, :eval_string, [expr])`) | `mix arbor.rpc` evaluates an operator CLI expression on the running node | Operator CLI args. Cookie possession is the only authority boundary (`remote_authority/0` → `:root`) | **Keep, flagged.** Removing it breaks live operator inspection. Not an HTTP or agent path. |

`Code.string_to_quoted` sites (parse-only; not loaders) include eval graders
(`Arbor.Eval.Graders.CompileCheck` — deliberately does **not** call
`Code.compile_string` because eval subjects are model output), platform
inventory, DOT source analysis, and `output_validate_handler` format checks.

The intended untrusted-eval path is **not** `Code.*`:
`Arbor.Sandbox.ExecSession` → `Dune.Session.eval_string/3`, reached from
agents via `Arbor.Sandbox.authorize_eval/4` (`arbor://sandbox/eval`). See
agent-security-gates §16.

---

## Vendor / Mix / tests (not in the production-lib allowlist)

| File:line | Call | Purpose | Untrusted input? | Disposition |
| --- | --- | --- | --- | --- |
| `clients/arbor_breeze/vendor/breeze/lib/breeze/template.ex:813,:848` | `Code.eval_quoted` | Fallback evaluation of Breeze template expressions that were not precompiled | Developer-authored templates shipped with the client | **Keep (vendor), flagged.** Do not patch vendored Breeze in this change. |
| `clients/arbor_breeze/vendor/breeze/lib/breeze/code_reloader.ex:102` | `Code.compile_file` | Reloads changed `.ex` files from configured paths | Project source on disk | **Keep (vendor).** |
| `clients/arbor_breeze/vendor/breeze/lib/breeze_storybook/registry.ex:51` | `Code.require_file` | Loads `*.story.exs` story modules | Developer story files | **Keep (vendor).** |
| `.formatter.exs:5` | `Code.eval_file` | Mix format imports Breeze's `locals_without_parens` export | Trusted vendored formatter config | **Keep.** Mix-time, not runtime. |
| `apps/*/mix.exs:1` | `Code.require_file` | Loads `build_support/mix_project_paths.exs` | Trusted Mix project helper | **Keep.** Mix-time. |
| `apps/arbor_gateway/lib/arbor/gateway/dev/router.ex` `POST /recompile` | `IEx.Helpers.recompile/0` (not a direct `Code.*` call) | HTTP-triggered recompile of **project files** | Trigger is HTTP; compiled bytes are the tree on disk | **Keep, flagged.** Agent-writable `lib/` could be compiled if an operator hits this opted-in localhost route. |
| Test `Code.compile_string` / `compile_file` / `eval_string` | various | Fixtures, hot-load harnesses, migration loading, `quote do: Code.eval_string(...)` AST samples for the sandbox | Test-controlled | **Keep.** Not production runtime. |
| `packages/conversation_kit/{test,scripts}` | `Code.compile_string` | Frozen baseline core for extension tests | Trusted package fixtures | **Keep.** Not the Arbor VM product path. |

---

## Flags for Hysun

1. **`mix arbor.rpc` remains unsandboxed.** Cookie possession is the documented
   root boundary. Routing it through Dune would stop it inspecting the live
   node (the feature). Do not delete without an operator replacement.
2. **`POST /api/dev/recompile`** still compiles whatever is on disk in a
   `:dev`/`:test` build with `dev_endpoints: true` from localhost. Not request-body
   eval. Confirm whether it should stay, be Mix.env-compile-out only, or require
   a second flag.
3. **Breeze vendor `Code.eval_quoted`.** A fork/patch is out of scope here.
   Confirm whether user-provided templates can reach the un-precompiled fallback.
4. **HotLoad still compiles a sandboxed AST into the host VM.** That is the
   product. Do not replace with Dune without an explicit hot-load redesign.

---

## Related regressions

- `apps/arbor_gateway/test/arbor/gateway/dev_eval_security_regression_test.exs`
  — HTTP body with `send(self(), :pwned_http_eval)` is not executed; Dev.Router
  AST has no `Code.eval_string`.
- `apps/arbor_actions/test/arbor/actions/code_hot_load_module_binding_security_regression_test.exs`
  — F-007 module binding + `:hot_load` sandbox.
- `apps/arbor_actions/test/arbor/actions/security/sweep_candidate_provenance_security_regression_test.exs`
  — F-008 never compiles caller `module_source`.
