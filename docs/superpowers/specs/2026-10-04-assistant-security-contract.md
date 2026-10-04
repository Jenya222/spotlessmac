# Assistant security contract

Date: 2026-10-04. Applies to the memory/assistant review fixes. Companion: [design](2026-10-02-cleanup-assistant-design.md), [review](../reviews/2026-10-04-memory-assistant-security-review.md), [verification](../reviews/2026-10-04-memory-assistant-fixes-verification.md).

## Guarantees and limits

The Assistant module cannot delete files or quit processes. Its only outward action is a value-only `stagePlan` closure that marks a selection for the existing preview; deletion still requires user confirmation and SafetyRules. Its tool set is closed: `list_items`, `item_details`, `propose_plan`, `lookup_knowledge`. Approved dependency count: 12. Source/import/member tests remain enforced without weakening forbidden tokens.

Four guard layers remain: local refusal of obvious instruction overrides; sanitized per-answer data fences; prompt/canary leak detection; code/command hiding. These filters and model instructions reduce risk and do not guarantee jailbreak resistance. Model answers may still be wrong; plans are resolved against the immutable snapshot and rechecked at preview staging. Bundled article text is maintained by the project, not supplied by scanned files.

Cloud privacy follows `sendsDataOffDevice`: Ollama Cloud always redacts and discloses, even on loopback; other providers exempt only localhost/127.0.0.1/::1. This contract does not expand the existing definition of personal folder names or claim anonymity for every arbitrary string. Unknown bare names, unfamiliar roots before registration, and app/cache names outside personal roots can remain visible; a newly registered root is applied to both current context and reusable safe history.

## Trust boundaries

| Source | Trust | Off-device redaction | Fence | Output control | Regression |
|---|---|---|---|---|---|
| Typed user question | User instruction, locally checked | Personal paths/known names | No (question remains the instruction) | Obvious injection refused locally and omitted from later context | `testInjectionIsAnsweredLocallyAndNeverSent` |
| Snapshot paths, file/app names, reasons | Untrusted local metadata | Render paths first, register aliases, then free text | Fresh per-answer tokens; strip fake boundaries and invisible characters | Text and reason screened before/after display restoration | `PathRedactorTests`, `AssistantGuardTests` |
| Row shortcut title/path/facts | Untrusted metadata; distinct from fixed question | Full path registered before bare title/facts | On send, retry and replay; pending disclosure/draft preserve the value | Same response guard | `testRowFocusIsFencedOnSendRetryAndReload`, `testCloudRowFocusRegistersPathBeforeBareNames` |
| Read-only tool result | Untrusted snapshot-derived text | Formatter uses current conversation policy | Per-answer fence | Same response guard; unknown tool denied | `testToolLoopFeedsResultsBack`, `testToolSetIsClosedAndReadOnly` |
| Bundled knowledge | Project-controlled reference | No private filesystem data is imported | Trusted separate reference; read-only lookup still wrapped as tool result | No executable action; reply guard remains | knowledge renderer/matcher tests, `testLookupToolReadsTheBase` |
| Model text and native/fallback plan reason | Untrusted output | Safe outbound representation retained separately from restored display | Not a new instruction boundary | Leak in either removes plan; code/commands hidden in both; raw fallback transcript checked | `testPlanReasonLeakDropsNativeAndFallbackPlan`, `testPlanReasonCommandsAreHidden`, `testBareCommandsUseSharedDetector` |
| Persisted cloud history | Reusable only through optional safe representation | Reapply current roots; old-scope aliases get opaque history namespace | Focus re-fenced for this answer | Saved model text already screened | `testRestartDoesNotExposeRestoredProjectNames`, `testRestoredAliasesCannotCollideWithCurrentSnapshot`, `testNewPrivacyRootReRedactsPreviouslySafeHistory` |
| Legacy/local history without safe text | Local display only | Omit from cloud context, including Retry; show notice | Never promoted to instruction from raw metadata | New fields optional; old JSON loads | `testLegacyAndLocalHistoryAreNotReplayedToCloud`, `testRestoredLocalAndLegacyRetryCannotCreateSafeHistoryFromRawNames` |
| Settings + credentials | Sensitive configuration | API key never enters snapshot/history/defaults/logs | Not model context | Endpoint-bound editor; immutable request pair; generation invalidates late probes | editor tests, `testSettingsChangeDuringRefreshDoesNotMixCredentials` |
| Current project roots | Value-only privacy policy | Refresh before each request; retain removed roots and aliases until new conversation | Not model instructions | No registry/scan/quit capability added | `testNewProjectRootIsRedactedWithoutRestart`, redactor update/overlap tests, isolation dependency test |

History JSON stores real display text locally plus safe outbound fields, not the alias-to-name map. Clearing the conversation writes an empty array immediately. A placeholder is saved at start; arriving screened partial text is checkpointed at most once per second; terminal state is saved. A restored stream is interrupted and retryable. Stop/New Conversation are checked before every round and fallback; a detached old response cannot modify the new conversation or write a capability result.

## Review-to-test mapping

| Review | Implemented boundary | Evidence |
|---|---|---|
| R01 / R10 | Endpoint-bound draft key; stale probes cannot change editor | `AssistantSettingsEditorTests` (unsaved B→C, both response orders, bindings, reset/save) |
| R02 | Capture endpoint and key synchronously before refresh | `testSettingsChangeDuringRefreshDoesNotMixCredentials` |
| R03 | Reason and text use one guard | native + fallback leak/command tests |
| R04 | Structured focus stored and fenced anew | row focus send/retry/reload + draft tests |
| R05 | Quit approval binds one launch, not a PID | `MemoryViewModelTests` reused-PID/relaunch/stale/missing-identity tests; fake terminator |
| R06 | Unknown metric availability reaches every consumer | `SystemMemoryReaderTests`, `MemoryVerdictTests`, history gaps, renderer/advisor/staging tests |
| R07 | Initial/partial/terminal persistence and clear ownership | `testOpenStreamCanBeRestoredAsInterrupted`, `testCheckpointPersistsScreenedPartialTextOnly`, cancellation race test |
| R08 | Explicit native replace, including empty; invalid calls unchanged | `testEmptyNativeReplacementRemovesPreviousPlan`, `testNativeReplacementAndInvalidCallsHaveDistinctSemantics` |
| R09 | Pure Markdown transform in domain module | `AssistantMarkdownBlocksTests`; full domain runner |
| R11 | Display separated from reusable cloud representation | restart, legacy/local retry, scope collision tests |
| R12 | Shared command detector after list/quote prefix stripping | bare command tests include `rm`, `killall`, pipe-to-shell, `/bin/rm`, `/BIN/rm`; Docker prose preserved |
| I01 | Host send right released on every exit | live host-reference probe (+10 before, 0 after ten reads), reader tests |

Automated regressions use synthetic snapshots, fake keys/clients, injected terminators and temporary conversation files. No real user-file cleanup, real application termination or live cloud transfer is performed by these tests. See the manual checklist for live-provider and macOS validation that remains necessary before release.
