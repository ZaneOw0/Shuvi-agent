# M2-B Phase 5 Authoritative Verification Report

**Final status: INCOMPLETE. Build/deploy scope: PASS. Feature delivery: PARTIAL, not accepted.**

Date: 2026-10-16. This is the single, exactly-once `spec-verify` invocation and its final authoritative report. No reinvocation is requested. T056/T057 have been processed; their checkboxes mean processed, not full feature acceptance. The 18 unfinished implementation tasks remain unchecked.

## Scope And Authority

- `PROJECT_ROOT=/Users/zane/DevecostudioProjects/Shuvi-agent`.
- Native home resolved to `/Users/zane`; `CONFIG_ROOT=/Users/zane/.local/share/deveco/`. Loaded `specs/commands/spec-verify.md` from that root and read this feature's spec, approved plan, tasks, implementation report, and context memory.
- `Confirmed_Feature_Dir=/Users/zane/DevecostudioProjects/Shuvi-agent/spec/knowledge-pdf-ingestion/` was used directly. `spec/feature.json` was neither read nor edited.
- `Verification_Scope=build-only`, from the parent's explicit instruction and tasks Phase 10 marker. T056 is compiler/build remediation; T057 is signed incremental install/launch. Authorized host regression after compiler fixes is supporting evidence, not service/device acceptance.
- Loaded `deveco-cli` and, before source fixes, `hmos-arkui-develop-skill`. Read the existing interfaces and adjacent implementations; searched/read official zlib documentation before changing the SDK buffer boundary. No unavailable legacy skill names, tool configuration edits, dependency installation, or project scaffold.

## Step Results

| Step | Status | Result |
|---|---|---|
| Baseline and public scripts | EXECUTED | Read approved artifacts, platform baseline, macOS signing and capture scripts; protected original dirty work and unrelated untracked work |
| Read-only target preflight | PASS | CLI device list/emulator list/view all RC0; exactly one active device, Mate 90 Pro / 127.0.0.1:5555; mapping consistent |
| Initial `arkts_check` | PASS, non-artifact | One call over 44 affected source/test `.ets` files: no errors. Immediately followed by initial build; no subsequent checker calls |
| Actual build 1 | FAIL, recovered | RC1; CompileArkTS reported 3 structural-typing locations, summary ERROR4/WARN638 |
| Compiler fixes | EXECUTED | Three infra files only; no gate removal, business completion, wire/ID change, or state-management migration |
| Actual build 2 | PASS | Direct retry RC0. Existing public filter withheld output; exit metadata is preserved, not bypassed |
| Post-fix host regression | PASS | 250/250, fail/cancel/skip/todo all 0, 72.001675334 s, process RC0; 217 old + 33 new tests and six fixtures/golden retained |
| Signed wrapper preflight 1 | BLOCKED | Proxy login precheck stopped, capture RC1. Actual build/run/signature generation calls: 0/0/0. No login attempted |
| Actual build 3, independent CLI | PASS | Existing cached signing reused; actual build RC0, BUILD SUCCESSFUL in 2.787 s. Guard intentionally refused wrapper auto-run before spawning CLI; aggregate wrapper/capture RC125 is preserved |
| T057 deployment | PASS, narrow CLI result | Separate `--no-build` wrapper invocation; exactly one actual `run --skip-build`, RC0. Signed package installed/launched to approved emulator without uninstall/reset/data clear |
| Template restoration | PASS | Before signing, after signed build, and after deployment SHA256 equal; final Git diff empty for template |
| UI prep/per-story loop/Phase 2 | SKIPPED BY SCOPE | No UI test plan generated, no stories executed, no UI interaction/screenshots or runtime probes. Phase 1 build/deploy evidence is authoritative |
| Evidence and closeout | EXECUTED | This report, task processing markers, context memory and aggregate spec updated incrementally; implementation history retained |

## Exact Attempts And Errors

Actual Phase 1 step 1 build count: **3/10**, comprising two direct builds and one build inside the normal macOS script. Results: **1 failed, 2 succeeded**. Actual deployment count: **1**, RC0; deployment rebuild count: **0**. Signature generation, forced signing, auth login, license acceptance, per-story builds, UI calls, device runtime tests and service tests: **0**.

Every actual build was preceded by `[BUILD_ATTEMPT]`. Attempt 3 was announced twice: the first wrapper stopped at login preflight before a build; the adjusted invocation performed the one actual third build. This is not four builds. The first failed build was followed by fixes and a direct build retry, with no second checker call. `code_modified=false` tracks only per-story fixes and remained false; compilation fixes do not change it. Phase 2 is inapplicable to build-only. The output marker was `[PHASE2_SKIPPED] reason=build_only`. No counter limit was exceeded.

Initial diagnostics, all `10605030 / arkts-no-structural-typing`:

| File, original location | Fix | Final SHA256 |
|---|---|---|
| `entry/src/main/ets/knowledge/infra/EmbeddingTransportAdapter.ets:33:113` | Promise reject parameter `Error` → explicit `Object`, matching the existing MinerU boundary; same KnowledgeFailure, timeout, cancellation and sanitization behavior | `6a71a23b46ffd0243ab35653f476435c5fcc254dedd5f396a80cedaedea99100` |
| `entry/src/main/ets/knowledge/infra/PdfArchiveAdapter.ets:62:36` | Copy the bounded input into an explicitly allocated `ArrayBuffer` for documented `ZStream.nextIn`; no cast from ArrayBufferLike, no unbounded inflate, same counters/CRC/budgets | `12938f8185af7e939f3f2e874052fecfa473ad7303c6c13162f5c7a883c64063` |
| `entry/src/main/ets/knowledge/infra/KnowledgeAssembly.ets:55:90` | Fix is in `PdfAssetAdapter.ets`: explicitly implement existing `KnowledgeDerivedCleanupPort` alongside `PdfAssetPort`; assembly call and cleanup behavior unchanged | `b58b67f4ea10a697276c50c79ac1ab96ee3500610d0984f634fcd5b697fb024a` |

The first checker did not detect these actual compiler failures; it is not treated as a build artifact or sufficient validation. Build 1 summary counted ERROR4 despite three listed source locations; the report preserves the tool's summary without inventing another diagnosis. No claim of warning-free compilation or separate full lint.

SDK evidence: `devecocli docs search ZStream nextIn --limit 3`, then `devecocli docs read API参考/基础功能/Basic_Services_Kit_基础服务/ArkTS_API/数据文件处理/ohos_zlib_Zip模块_/js-apis-zlib`. API12+ ZStream documents `nextIn: ArrayBuffer`; this establishes typing, not native runtime safety. No new SDK API was introduced.

## Deployment And Artifact Identity

Bundle: `com.example.shuvi`; product `default`, debug; current HEAD `9f5992c3945975b97349767f0c9e0b4777920ecd`, branch `dev/rag`, plus uncommitted implementation and the three compiler fixes.

Read-only CLI inventory showed Mate 90 Pro phone, running at `127.0.0.1:5555`, HarmonyOS 7.0.0(26.0.0); view reported API26 Release. The other three emulators were stopped. The unchanged normal macOS script rechecked inventories/view before both signed build and deploy; the verification guard additionally checked unique device/emulator/view mapping immediately before the sole real run. No guessed target, alternate instance, emulator restart, HDC command or HDC file-write bypass.

The first proxy preflight could not confirm login. The previous M2-A report documented the same routing issue; the adjusted child used the already installed independent CLI at `/Users/zane/.local/share/fnm/node-versions/v22.23.2/installation/bin/devecocli`, with only `DEVECO_CLI_AUTH_SOURCE` and `DEVECO_CODE_AUTH_DIR` removed from that child's environment. No account/credential file was read by the agent, no login performed, no global configuration changed. The script publicly confirmed existing login state and cache reuse. Raw auth/signing output stayed private under the existing script's control and was not read or copied into public evidence.

An ignored verification-only executable `.cache/m2b-verify-cli-guard.cjs` was used as `DEVECOCLI_BIN`; it does not replace/edit the normal script or signing configuration. It rejects signature generation and unauthorized commands, allows at most one signed-wrapper build and one deployment, requires a successful signed build before run, revalidates target mapping, and bounds the actual run to 120 seconds. It intentionally blocks the signed-build wrapper's auto-run with RC125 so deployment is a separate step. No run retry or timeout occurred. Its journal contains operation/RC/timestamp only; final guard SHA256 `c34cc9a9f2c41a7603bdaba318f9bdd8d08ae0d310ce6a7544e930db6f8647b3`. Do not rerun its already-processed phases or delete its journal to bypass the exactly-once restriction.

| Artifact | Bytes | mtime UTC | SHA256 |
|---|---:|---|---|
| `entry/build/default/outputs/default/entry-default-signed.hap` | 2271306 | 2026-10-16T10:12:06.356Z | `6670bc403f2559da33ffe4ab35382d6b8efc6f825d5bd06789bf0cc7ba8a27f8` |
| `entry/build/default/outputs/default/entry-default-unsigned.hap` | 2220698 | 2026-10-16T10:12:05.513Z | `0ed3132062f918ad9aa23142347628ea70a9698d3b089a0083c55bbbc9e85f30` |
| `build/outputs/default/Shuvi-agent-default-signed.app` | 2236997 | 2026-10-16T10:12:06.691Z | `5422242227be7ab252b29e57706db4463d5c40b135d155b254b1ff63a2ad95c7` |
| `build/outputs/default/Shuvi-agent-default-unsigned.app` | 2222236 | 2026-10-16T10:12:06.625Z | `dcd4fa89dd8f98f9e84a900e0f05f60bd86c75982b8e04bfc122001aa288afc2` |

Actual deployment ran 2026-10-16T10:12:34.505Z–10:12:37.984Z, RC0. This proves the CLI install/launch result, not sustained process health, page rendering, data migration success, PDF ingestion, KNN, semantic quality, or end-to-end service behavior. No runtime test probes followed deployment. Existing application data was not intentionally removed or replaced by a reset; data integrity at runtime was not independently tested.

Unsigned template SHA256 throughout: `36852083144377348c92aafdf42381978ba9d46a4a2c811c0ad39582ff4a2fb7`. Final audit verified clean template diff, unchanged dependencies/permissions/SDK configuration, unchanged normal macOS script, old M1 view and six fixtures/golden. No `.p12`, certificates, profile, Key, credentials, signing cache or `.local` content was inspected by the agent. Only the approved script internally reused its normal cache.

## Evidence And Commands

All directories below are under `.cache/test-logs/`, with full names **`2026-10-16-<scope>-9f5992c/`**. Every command was captured using existing `/bin/bash scripts/capture-test-log.sh`, `CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1`. Each directory has `host.log` and `meta.txt`, and is indexed in `.cache/test-logs/index.tsv`. Command RC and log RC are separate: device `log_exit=not-run`, `status=skipped-host-only` throughout, intentionally. No device-log collection was authorized, and absent device logs are not a PASS or unresolved UI failure.

| Scope | cmd RC | Evidence |
|---|---:|---|
| `m2b-verify-target-preflight` | 0 | Public device/emulator/view JSON, consistent unique authorized mapping |
| `m2b-verify-build-01` | 1 | Public compiler diagnostics; original full compiler log reference preserved |
| `m2b-verify-build-02` | 0 | Successful command metadata; public output withheld by existing conservative filter |
| `m2b-verify-buildfix-host` | 0 | 250/250 summary, 72.001675334 s, offline ZIP/structure metadata only |
| `m2b-verify-template-before` | 0 | Template SHA256 before signing |
| `m2b-verify-signed-build-03` | 1 | First proxy preflight blocked before any build/run |
| `m2b-verify-signed-build-03-independent` | 125 | Public cache/build-success stages; aggregate RC125 is intentional pre-run guard refusal, not failed signed build |
| `m2b-verify-template-after-signed-build` | 0 | Restored template hash and empty Git diff |
| `m2b-verify-deploy-01` | 0 | Cached signing, skipped build, sole install/launch RC0 |
| `m2b-verify-template-after-deploy` | 0 | Final restored template hash and empty Git diff |
| `m2b-verify-final-audit` | 0 | Current artifact/fix hashes, actual command counters, preserved gates and unchanged protected files |

Public checker transcript: `.cache/arkts-check/m2b-phase5-initial.txt` (44 files, clean, one tool invocation, not compiler artifact). Additional non-secret audit files: `.cache/m2b-verify-cli-events.jsonl`, `.cache/m2b-verify-signed-build-summary.log`, `.cache/m2b-verify-final-audit.cjs`. Signed summary records actual build RC0 and BUILD SUCCESSFUL without reading private script logs. The manual final audit is host-filesystem/command evidence only, not a device test.

Build 1 fingerprint: `7cf7a246f0874ba1fcbfda7da114a6ca89e7b53fdb5116b890db018f97b8b0b2`. Build 2, post-fix host, signed build and deployment share fingerprint **`543823a4de417a5cfc27615f8b5f201a3bc200f81596a11816b851f92177536b`**, dirty_files=57. The fingerprint deliberately excludes unrelated scripts/private paths/signing config; ignored guard is separately hashed. Subsequent documentation closeout changes the public feature fingerprint, not the verified source. Node v22.23.2, macOS Bash 3.2.57; existing API26 toolchain unchanged.

Exact direct build command, used twice with scopes `m2b-verify-build-01` and `m2b-verify-build-02`:

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 RUN_CMD='devecocli build --product default' \
  /bin/bash scripts/capture-test-log.sh m2b-verify-build-01
```

Exact post-fix host command:

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" \
RUN_CMD='node entry/src/test/run-host-summary.cjs' \
  /bin/bash scripts/capture-test-log.sh m2b-verify-buildfix-host
```

Initial blocked wrapper command used `M2B_VERIFY_PHASE=signed-build DEVECOCLI_BIN="$PWD/.cache/m2b-verify-cli-guard.cjs" /bin/bash scripts/dev-run-mac.sh --device 127.0.0.1:5555 --emulator "Mate 90 Pro" --no-emulator --product default` within RUN_CMD and scope `m2b-verify-signed-build-03` (before guard was routed to the installed independent CLI). No actual third build occurred there.

Successful signed build and the separate deployment were these commands; they are an audit record, not permission to reinvoke Phase 5:

```bash
CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='env -u DEVECO_CLI_AUTH_SOURCE -u DEVECO_CODE_AUTH_DIR DEVECO_HOME="/Applications/DevEco-Studio.app/Contents" M2B_VERIFY_PHASE=signed-build DEVECOCLI_BIN="$PWD/.cache/m2b-verify-cli-guard.cjs" /bin/bash scripts/dev-run-mac.sh --device 127.0.0.1:5555 --emulator "Mate 90 Pro" --no-emulator --product default' \
  /bin/bash scripts/capture-test-log.sh m2b-verify-signed-build-03-independent 30m 127.0.0.1:5555

CAPTURE_SAFE_HOST=1 CAPTURE_HOST_ONLY=1 \
RUN_CMD='env -u DEVECO_CLI_AUTH_SOURCE -u DEVECO_CODE_AUTH_DIR DEVECO_HOME="/Applications/DevEco-Studio.app/Contents" M2B_VERIFY_PHASE=deploy DEVECOCLI_BIN="$PWD/.cache/m2b-verify-cli-guard.cjs" /bin/bash scripts/dev-run-mac.sh --device 127.0.0.1:5555 --emulator "Mate 90 Pro" --no-emulator --no-build --product default' \
  /bin/bash scripts/capture-test-log.sh m2b-verify-deploy-01 30m 127.0.0.1:5555
```

The sole actual deploy command inside the unchanged script/guard was `devecocli run --skip-build --product default --device 127.0.0.1:5555`. Preflight command: `devecocli device list --format json && devecocli emulator list --format json && devecocli device view -t 127.0.0.1:5555 --format json`. Template captures used `node scripts/dev-run-support.cjs hash build-profile.json5`, followed after restoration by `git diff --exit-code -- build-profile.json5`. Final audit command: `RUN_CMD='node .cache/m2b-verify-final-audit.cjs'` with the same safe capture flags and scope `m2b-verify-final-audit`. `git diff --check` also returned RC0, but is not compiler/runtime acceptance.

## Unverified And Unfinished Scope

No per-story pass/fail or UI retry counts exist because build-only expressly excludes that work. No UI test plan generation, `verify_ui`, screenshots, manual UI commands, device application/database/file/process probes, real MinerU, live model discovery, embedding probe, corpus/query embedding, full-chain service tests or quality evaluation were performed. Missing UI is not itself the reason for this report's INCOMPLETE status.

Implementation remains **37/55 completed and 18 unfinished**: T023, T026, T029, T031–T032, T035–T037, T039, T041–T043, T045–T048, T050, T052. Their exact implementation gaps and next steps remain in `implementation-report.md`; no task was implemented or batch-checked merely to compile.

- ZIP/structure platform cases are incomplete; bounded JSON still lacks the approved background segmented worker. Asset/image validation, interrupted writes/startup recovery and full 500 MiB accounting remain incomplete.
- PDF review/rebuild/recovery UI and job handling, accurate original-page/region evidence, verified multi-region highlighting and full structural/image/table review remain incomplete. Service-derived PDF is not the original.
- US5 is **not delivered**, not merely blocked on a user Key: corpus/query orchestration, persisted coverage/readback publication, cross-store eligibility/recovery, query KNN orchestration and independent consent UI are unfinished. Same-space RRF pure policy does not prove real semantic retrieval.
- Vector store registration/reopen/capability evidence, cross-store cleanup coordination, retained generations, complete lifecycle fault cases, unified management and global vector/asset ledger remain incomplete.
- Native production ingestion remains closed with `NativeZlibRuntimeUnverified`; vector production open remains closed with `VectorStoreRuntimeUnverified`; corpus/query remain `InputLimitUnverified`. Gemini/OpenAI network remains disabled; no new provider/model/backend was introduced. No gate was removed to obtain a build.
- No real embedding Key was available or accessed; safety SDK behavior, native zlib counters/CRC/cancel/release, actual ArkData migration/reopen/vector write-read/KNN, PDFKit behavior, original-page/region correctness, OCR/formula/table content quality and keyword/vector/hybrid semantic quality remain unverified.
- The authorized existing ZIP host recheck retained 70/70 CRC, expanded 11,926,995 bytes, 346 primary blocks / 340 inline formulas / 46 display formulas / 7 tables / 248 cells. This is offline host substitute evidence, not app-native validation. The app result remains **UNVALIDATED**.

No private/user paste script was read or run, no unrelated feature was changed, no secrets entered the report/logs, no user data was cleared, and no Git write/commit/push occurred. Normal generated build artifacts and ignored audit evidence are local only.

**Authoritative closeout: T056 PASS after one compiler-fix cycle; T057 PASS with one signed incremental install/launch RC0; overall INCOMPLETE and feature PARTIAL because implementation and acceptance obligations above are not complete.** Phase 2 was skipped by build-only scope, so these Phase 1 results are final. Historical implementation/failed-build/preflight evidence is retained. No second verification invocation is required or authorized by this report.
