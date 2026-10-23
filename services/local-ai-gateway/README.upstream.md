> 历史来源文档：来自 local-ai-gateway 固定提交 `21017a1`，正文保留原文，仅供追溯。原机器路径、状态与操作记录不代表 Shuvi 当前环境。当前规则见主仓库 `docs/01-协作与工程约定.md`；接入和验证见本目录 README.md。

# Local AI Gateway

Private Windows local AI gateway. M0-M3f provide configuration, Windows credentials,
the loopback-only Kestrel/YARP edge, a hash-locked private Python/LiteLLM text runtime,
suspended Job Object process containment, and a current-user single-instance production
composition, a current-user Named Pipe control plane, blue-green backend switching, a
complete deterministic runtime ZIP, and an isolated atomic install/uninstall core.
The M3g repository-only token, path, install transaction, cross-process lock, lifecycle
CLI, daemon controller, and optional current-user Task Scheduler autostart contract are
also implemented and locally verified; current packages manage Runtime and Tray as one paired
login-autostart choice. M4 adds the client-independent launcher process core,
packaged `aigw-launcher.exe`, fixture-verified `aigw run` adapters for Claude, Codex, and
explicit custom clients, a read-only fixture-driven integration preview, and an explicitly
confirmed atomic apply transaction tested only on fixtures. It does not automatically discover,
read, or write external client configuration. M4e, the locally verified M5a privacy-bounded usage storage, and M5b
are merged into `codex/develop`. M5b adds the read-only usage query plus a standalone, single-instance WPF Tray
for daemon status/control, active-profile display, profile switching, and today's Token totals. M5c's plain and
Argon2id/AES-GCM provider-credential backups are also merged into `codex/develop`. M5d's manifest-bound Ed25519
offline updates, self-contained external updater, side-load health checks, atomic switching, and automatic rollback
are merged there as well. M5e's nine-category interactive/non-interactive complete uninstall, explicit owned
integration and backup targets, exact credential namespaces, and external installed-program removal worker are also
merged into `codex/develop`. M6a's bounded Edge retries and `Retry-After` handling are merged there as well. M6b's
per-model-target closed/open/half-open circuit breakers and status/read-only-doctor/Tray exposure are also merged there.
M6c ordered fallback and M6d smooth weighted round robin are also verified and merged into `codex/develop`.
M6e's verified profile/provider/model concurrency, rolling RPM, and actual-response-usage TPM limits are also merged.

## Development

Requirements: Windows x64 and the .NET SDK selected by `global.json`.

```powershell
./scripts/build.ps1
./scripts/test-m3e-runtime.ps1
./scripts/test-m5a-usage-callback.ps1
./scripts/test-m5b-usage-query.ps1
./scripts/test-m5b-tray.ps1
./scripts/test-m5c-backup.ps1
./scripts/test-m5d-update.ps1
./scripts/test-m5e-uninstall.ps1
./scripts/test-m6a-edge-retry.ps1
./scripts/test-m6b-circuit-breaker.ps1
./scripts/test-m6c-ordered-fallback.ps1
./scripts/test-m6d-weighted-round-robin.ps1
./scripts/test-m6e-rate-limits.ps1
./scripts/test-release-log-lifecycle.ps1
./scripts/test-release-install-experience.ps1
./scripts/verify-m3f-package.ps1
```

GitHub Actions runs the source CI on pushes to `codex/develop` or `main`, pull
requests into either branch, and manual dispatch. Its Windows runner restores the
SDK and existing NuGet dependencies, then runs `scripts/build.ps1` for a Release
build, all solution tests, and the source sensitive-data scan. CI deliberately
does not make a release ZIP: complete packaging requires the separately assembled
private Python/LiteLLM runtime under ignored `artifacts/`, which a clean GitHub
runner does not have. A green source CI result is not an offline-package or
clean-machine installation acceptance result.

`test-m3e-runtime.ps1` is the non-optional real-assembly acceptance command for
M3e. It fails when the private assembly is absent and verifies control status/reload/stop,
blue-green readiness, zero private Python processes, instance state, bytecode, and cache
residue after shutdown.

`verify-m3f-package.ps1` refuses pre-existing M3f output/acceptance roots, creates two
complete unsigned ZIPs without restore or download, compares their SHA-256 hashes,
verifies all manifest entries, runs CLI/Runtime/private-Python smoke tests, installs into
an isolated path containing spaces, runs the real M3e acceptance, uninstalls, and removes
the acceptance root. The retained ZIP is self-contained; using the verification script
itself requires PowerShell, but the packaged executables and private runtime do not.

## M2 runtime

`aigw-runtime.exe` is an independent loopback HTTP process. M2 exposes only:

- `POST /v1/chat/completions`
- `POST /v1/responses`
- `POST /v1/messages`
- `GET /v1/models`
- `GET /health`
- `GET /ready`

Every request requires the local gateway token as either `Authorization:
Bearer <token>` or `x-api-key: <token>`. Model names are public aliases from the
active profile; the runtime rewrites an accepted alias to its configured
canonical public alias before forwarding. A profile-private LiteLLM configuration
maps that alias to the provider and upstream model. Unknown aliases are rejected
without reaching the backend. Text responses, tool-call payloads, upstream error responses, and
SSE streams are forwarded without response aggregation. M6a adds bounded response-before-first-byte retries as
described below; a stream is never retried after its first byte reaches the client.

The explicit `--m2-test-serve` bootstrap remains gated by `AIGW_M2_TEST_MODE=1`
for deterministic development verification. M3d adds the production `--serve`
composition and M3e adds Named Pipe control plus blue-green reconfiguration;
M3f adds the complete package and isolated file-lifecycle core. M3g now adds generated
runtime tokens, fixed current-user paths, a locked package-plus-credential transaction,
and `install|uninstall|start|stop|restart|status`. Real current-user writes, Task
Scheduler provisioning, and login autostart have not been executed.

## M3a LiteLLM contracts

`LocalAIGateway.LiteLlm` currently compiles deterministic, secret-free YAML-compatible
configuration, injects credentials only through controlled child-process environment
variables, disables LiteLLM retries/telemetry and third-party callbacks, and forces the bundled local model cost
map. Its process-start specification uses an argument list and a fixed Python call to
the official `litellm.run_server` entry point, disables shell execution, and defines a
minimal non-inherited environment. Managed process tests cover prepare,
probe, drain, concurrent stop, failed cleanup, and retryable stop tracking.

The repository now has a local, ignored M3b runtime assembly and repeatable assembly,
verification, pruning, and loopback smoke-test scripts. M3c adds a concrete Windows
process factory and Job Object lifecycle. M3d composes that factory behind the edge;
M3e adds the current-user control pipe and blue-green switching. Installer and packaged
runtime integration are implemented in M3f. M3g's repository-only preparation preserves
valid existing runtime credentials, rolls back only newly installed package files when
credential creation fails, and retains credentials after a conservative partial uninstall.
It also adds a SID-scoped installation Mutex and tested daemon start/stop/status control.
It has not written the real Local AppData roots or Windows Credential Manager.

## M3c suspended process lifecycle

`WindowsLiteLlmProcessFactory` writes the secret-free configuration to a random owned
instance directory and launches the private Python runtime with `CreateProcessW` in a
suspended state. Standard handles are restricted to `NUL`; the process is assigned to a
kill-on-close Job Object before its main thread is resumed. The temporary Unicode
environment block is zeroed after process creation, and stop waits for the process tree
before deleting only the owned instance directory.

Native integration tests verify that an actual parent and descendant both exit when the
Job is terminated. A separate environment-gated test starts the real M3b LiteLLM assembly
from a state path containing spaces and validates ready, drain, stop, zero private Python
processes, and zero test-root residue without making a model request.

## M3d production runtime composition

`aigw-runtime.exe --serve` acquires a SID-scoped global Windows Mutex before reading
configuration or credentials, loads the client token from
`LocalAIGateway/runtime/client-token`, composes the private LiteLLM backend, and exposes
it through the fixed loopback edge. A second instance fails with exit code 12. Backend
readiness is polled for at most 60 seconds so a cold private Python import cannot be
mistaken for a permanent failure.

Shutdown stops new edge traffic, drains and terminates the private Job process tree,
disposes the backend, and releases the single-instance lease last. The real M3b assembly
has passed this complete composition without a model request and with zero instance,
Python-process, bytecode, or cache residue. The client token is an installer-owned
credential; `--serve` deliberately fails if it has not been provisioned.

## M3e control plane and blue-green reload

The production runtime listens on `LocalAIGateway.Control.v1.<current-user-SID>` with
`PipeOptions.CurrentUserOnly`. Protocol v1 is one 4-byte little-endian length-prefixed
UTF-8 JSON request and response per connection, capped at 64 KiB. It accepts only
`status`, `reload`, and `stop`; status excludes tokens, ports, and process arguments,
reload rereads the configuration store, and stop writes its acknowledgement before
requesting shutdown. The reusable Windows client applies bounded connect and I/O timeouts.

Reload prepares and probes a higher-revision candidate before atomically publishing an
immutable route. Each request, including an SSE stream, holds a lease that binds its
configuration, profile, model rewriter, backend endpoint, and internal token. New requests
use the candidate after the swap; the retired route drains and stops only after its leases
finish. Candidate failure preserves the active route and reports the pending revision;
equal revisions are idempotent and older revisions are rejected.

## M3b locked text runtime

`runtime-manifests/m3b-proxy-without-enterprise.candidate.json` records the approved
Windows x64 candidate download set: CPython 3.14.5 plus 107 wheels derived from the
official LiteLLM 1.95.0 proxy closure with the proprietary `litellm-enterprise` package
excluded. The immutable pre-download manifest retains its original status, and
`runtime-manifests/m3b-download-verification.json` records the original 108-file result.

The final source directory contains 109 hash-verified files (the original 108 plus
`cl100k_base.tiktoken`) totaling 141,287,210 bytes. The deterministic lock
`runtime-manifests/m3b-text-runtime.lock.json` selects CPython, 87 wheels, and the BPE
data: 89 compressed inputs totaling 83,827,724 bytes. Twenty downloaded wheels are
excluded, including `soundfile`/libsndfile, alternate servers, proxy database/queue,
analytics, interactive CLI, and Azure identity packages outside the API-key-only contract;
`litellm-enterprise` remains excluded upstream. The tokenizers Apache-2.0 license is
packaged as a supplemental notice.

Offline loopback smoke testing starts the actual LiteLLM 1.95.0 proxy and validates
OpenAI-compatible, local endpoint, Anthropic, and Azure OpenAI v1 mappings against a
deterministic fake upstream. Chat Completions, Responses, Anthropic Messages, SSE, and
tool calls are covered. Python uses `-B -I`; process TEMP, home, AppData, and common
third-party cache roots are contained under `runtime-state`, which is empty after cleanup.
The assembly was freshly rebuilt from the 109 source inputs without package-manager
installation; it contains 10,699 files and 206,297,020 bytes. A hard-link mirror verified
the same smoke suite from a space-containing path and was removed with zero residuals.
Repeated cold starts passed while the Codex sandbox denied outbound sockets. Product
Runtime composition and isolated installation now pass from the complete M3f ZIP. A
separate OS firewall/VM air-gap test and real current-user installation remain pending.

## M3f complete package and isolated installer

The retained unsigned package is written to
`artifacts/m3f-package-output/LocalAIGateway-0.1.0-dev-win-x64-unsigned.zip` with its
`.sha256` sidecar. It includes `runtime/python/python.exe`, lock/receipt/environment audit
material, third-party licenses, `PRIVATE-RUNTIME-COMPONENTS.json`, and a canonical
`PACKAGE-MANIFEST.json`; runtime state, bytecode, source downloads, wheel archives, and
package-manager caches are excluded.

`WindowsPackageInstaller` validates exact source contents before mutation, copies to a
sibling random staging directory, verifies every file, and atomically publishes by
directory rename. Reinstalling the same package is idempotent; a different package is a
non-mutating conflict. Uninstall deletes only unchanged manifest-owned files and preserves
unknown or modified content. M3f does not write `%LOCALAPPDATA%`, Credential Manager,
Task Scheduler, PATH, Start Menu, or client configuration.

## M3g lifecycle CLI

The source tree contains `aigw install`, `uninstall`, `start`, `stop`, `restart`,
`status`, read-only `doctor`, and `autostart enable|disable|status`. Installation is current-user
only. Interactive `install` asks `Enable Runtime and Tray login autostart? [Y/n]` and defaults
to enable. Machine-readable installation must make the choice explicit before any mutation:

```powershell
aigw install --autostart enable --json
aigw install --autostart disable --json
```

Omitting `--autostart` with `install --json` returns exit code 15 and
`aigw_install_autostart_choice_required`. Installation does not start either process. Runtime
start uses only the fixed installed `aigw-runtime.exe --serve`; status and stop use the
current-user Named Pipe. The CLI never returns the generated runtime token.

For the first M3g contract, uninstall must be run from the original extracted package,
outside the installation root. Running uninstall from the installed directory fails
before stopping the daemon or changing files, avoiding Windows self-deletion ambiguity.
A dedicated uninstall helper remains planned for M5. The current M3g development artifact is:

`artifacts/m3g-package-output/LocalAIGateway-0.1.0-dev-win-x64-unsigned.zip`

Its SHA-256 is `03a2c977d38ee868ee904018f479b4bd521fc1182d21239208dc15547689004a`.
It was independently rebuilt twice, includes the autostart commands, and passed isolated
package install/uninstall. The retained M3f ZIP is historical and does not contain the M3g lifecycle CLI.
The same ZIP and sidecar are copied to `C:\Users\Admin\Desktop\LocalAIGateway-M3g`.

`aigw doctor` checks only local path/file presence and current-user Pipe status. It does
not create or repair state, start the runtime, read upstream secrets, make a model request,
or contact an upstream endpoint. Its machine output explicitly reports both probe flags.

The first real current-user M3g acceptance installed the complete candidate, preserved the
same package and runtime credential on a repeated install, ran installed read-only diagnostics,
and uninstalled from the external extracted package. Independent cleanup checks found no
program root, state root, staging directory, installed process, runtime credential, extracted
candidate, ZIP, or acceptance root. This acceptance deliberately did not create configuration,
start the daemon, register autostart, modify PATH, or create a shortcut.

The installed-daemon acceptance now also creates a local-only profile without an upstream
secret, starts the installed runtime with its real Credential Manager client token, verifies
an idempotent repeated start and current-user Pipe status, confirms unauthenticated `/ready`
returns 401, and stops/uninstalls with zero residue. It performs no model request and contacts
no upstream endpoint. Task Scheduler login autostart is implemented in the current source
and package. Real registration, scheduler-normalized semantic readback, idempotent enable,
manual Scheduler action execution, disable, uninstall, and zero-residue cleanup passed.
An authorized 2026-09-22 acceptance also signed out and back in: both task run times advanced
from the recorded baseline, Runtime logged `daemon.started` at configuration revision 4, and
Tray started exactly one process from the owned installation path.

Current packages use two fixed task paths. `\LocalAIGateway.Runtime` runs the installed
`aigw-runtime.exe --serve` from the installation root. `\LocalAIGateway.Tray` runs the
installed `tray\aigw-tray.exe` with no arguments from the tray directory. Both use only the
current SID, `LogonTrigger`, `InteractiveToken`, and `LeastPrivilege`. A different task at
either path is never overwritten or deleted and blocks the transaction before package or
credential mutation. A legacy Runtime-only owned state is reported as incomplete; enable
adds only the missing Tray task. Disable and uninstall remove only semantically matching
owned tasks. If a later installation step fails or is cancelled, rollback removes only files,
credentials, and tasks created by that invocation and preserves all pre-existing owned state.

Current-user installation also appends the exact program root once to
`HKCU\Environment\Path` and creates only one Start Menu shortcut,
`Local AI Gateway\Local AI Gateway.lnk`, targeting the installed Tray executable. An ownership
receipt under `LocalAIGateway\installation` makes both changes reversible. Uninstall preserves
the original PATH value type and text byte-for-byte, including separators, and removes only the
owned shortcut/directories. A pre-existing equivalent PATH entry, shortcut, malformed receipt,
or reparse-point boundary is a conflict and is never overwritten.

Run `./scripts/test-release-install-experience.ps1` for the repository-only transaction tests,
self-contained CLI help, explicit-choice gate, and version-binding smoke. These tests use a
random repository-local root and do not write the real Task Scheduler or Credential Manager.
Run `./scripts/test-m3g-installed-runtime.ps1 -TestAutostart` for a read-only exact-target
preview. Its current-package execution path covers both tasks, but add `-Execute` only after
approving the displayed external writes and cleanup. The previously completed real acceptance
proved the Runtime task. A later authorized run proved the current Tray Scheduler action and
zero-residue cleanup. The automation environment initially made a controller-written config
invisible to an independent Scheduler process even though SID, session, and `LOCALAPPDATA`
matched. A task-context probe reproduced that file-view split. After staging the same local-only
revision 4 configuration from Task Scheduler context, the unchanged direct Runtime action passed,
remained running throughout a 95-second observation, and the paired real logon event passed.
A clean-machine/air-gap run remains outstanding.

For the current private-use workstation, that external release gate is intentionally deferred rather than passed.
The verified `f1de4b0` unsigned package is installed under the fixed current-user Local AppData layout with login
autostart disabled. Its retained extracted source is on `H:\LocalAIGateway\install-source-f1de4b0`; the next
practical step is to create and activate the first provider/profile before starting the Runtime. Large development
downloads, caches, temporary package builds, and acceptance roots should prefer a non-system drive when their exact
ownership and cleanup boundaries are known. Product installation and state paths remain fixed Local AppData paths.

## M4a launcher core

`LocalAIGateway.Launcher` validates an absolute client executable and working directory,
reads the generated installation token from Windows Credential Manager, starts the fixed
installed daemon if necessary, and launches the client without a shell. Client arguments
use `ProcessStartInfo.ArgumentList`; the gateway base URL and token are written only into
the child launch environment, and the launcher returns the child's exit code.

The direct `aigw-launcher.exe` interface is the internal composition boundary used by
`aigw run` and the Claude VS Code process-wrapper preview. Environment variable names are
supplied by a reviewed client adapter; M4a itself
deliberately does not guess Claude or Codex contracts. No real Claude, Codex, or VS Code
configuration was read, written, or launched during M4a verification.

## M4b client adapters

Known clients are launched with arguments after `--`:

```powershell
aigw run claude -- --print "hello"
aigw run codex -- exec "prompt"
```

The Claude adapter uses the official `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`
process environment contract and fixes the model to `aigw/default`. The Codex adapter
uses one-shot `--config` values for a custom Responses provider at
`http://127.0.0.1:4000/v1`, reads its child-only token from `AIGW_CODEX_API_KEY`, and fixes
the model to `aigw/codex/default`. Conflicting model/provider overrides are rejected.

Only native `claude.exe` and `codex.exe` files in absolute PATH directories are resolved;
shell shims are not executed. A custom native client can be launched explicitly:

```powershell
aigw run --client C:\absolute\client.exe --base-url-env CLIENT_BASE_URL --token-env CLIENT_TOKEN -- --flag value
```

These commands start the installed gateway as needed and require its installer-owned runtime
credential. They do not edit Claude, Codex, or VS Code configuration. M4b verification used
fixtures only and did not run the real clients or contact a model provider.

## M4c integration preview

`integrate preview` operates only on an explicitly supplied fixture, or previews creation when
`--source` is omitted. It never reads the represented `--target` and never writes a file:

```powershell
aigw integrate preview --client codex-cli --target C:\fixtures\codex-home\aigw.config.toml --client-version 0.134.0
aigw integrate preview --client claude-vscode --source C:\fixtures\settings.json --target C:\represented\settings.json --client-version 2.1.257 --host-version 1.94.0 --wrapper C:\fixtures\aigw-launcher.exe
```

Claude VS Code preview owns only `claudeCode.claudeProcessWrapper` in a marked JSONC block;
comments and unrelated properties are preserved. Codex preview represents only the separate
`$CODEX_HOME/aigw.config.toml` profile file, never the default `config.toml`, and stores an
environment-variable name rather than a token. Output contains the managed block diff and
before/after hashes, not unrelated fixture values. Unknown reviewed-version ranges, unowned
fields, malformed markers, or user content inside a managed block fail with exit code 14.

The current preview gate accepts Claude Code 2.x with VS Code 1.94+, and Codex 0.134+ while
Codex remains on major version 0. Real client configuration still requires a separate
exact-target approval.

## M4d confirmed fixture apply

Apply binds the write to both hashes emitted by preview. For a new fixture, pass
`--expect-absent`; for an existing fixture, pass its `beforeSha256`:

```powershell
aigw integrate apply --client codex-cli --target C:\fixtures\aigw.config.toml --client-version 0.134.0 --expect-absent --expected-after-sha256 <preview-after-sha256> --confirm APPLY
aigw integrate apply --client claude-vscode --target C:\fixtures\settings.json --client-version 2.1.257 --host-version 1.94.0 --wrapper C:\fixtures\aigw-launcher.exe --expected-before-sha256 <preview-before-sha256> --expected-after-sha256 <preview-after-sha256> --confirm APPLY
```

The exact uppercase confirmation is checked before target access. Apply rereads strict UTF-8,
recompiles the owned block, rejects stale before/after hashes and reparse-point paths, and does
not create parent directories. Existing files use a write-through sibling temporary file plus
atomic `File.Replace`, which leaves a uniquely named recovery backup; new files use a no-overwrite
sibling move. Existing UTF-8 BOMs are preserved. Output contains hashes and the backup path, not
configuration contents. The current verification used disposable fixtures only; do not point
this command at real Claude, VS Code, or Codex configuration without an exact-target review and
approval.

## M4e owned integration status and removal

`integrate status` reads only one explicit target. It does not discover clients, scan default
configuration paths, or write a registry:

```powershell
aigw integrate status --client codex-cli --target C:\fixtures\aigw.config.toml
aigw integrate status --client claude-vscode --target C:\fixtures\settings.json
```

The result is `absent`, `not-integrated`, or `owned`. An owned result includes a redacted removal
diff and the before/after hashes needed for the confirmed operation. It does not output unrelated
configuration values. Status does not require a client version because it only recognizes an
existing Local AI Gateway v1 ownership marker; creation and update remain version-gated.

For an update plan, bind both hashes. For a fully owned Codex profile, bind the before hash and
the planned deletion:

```powershell
aigw integrate unintegrate --client claude-vscode --target C:\fixtures\settings.json --expected-before-sha256 <status-before-sha256> --expected-after-sha256 <status-after-sha256> --confirm UNINTEGRATE
aigw integrate unintegrate --client codex-cli --target C:\fixtures\aigw.config.toml --expected-before-sha256 <status-before-sha256> --expect-delete --confirm UNINTEGRATE
```

The exact uppercase confirmation is checked before target access. Updates use the same atomic
replace and unique recovery-backup transaction as apply. A fully owned Codex profile is moved
atomically to its recovery backup instead of leaving an empty file. Ownership conflicts and stale
status plans fail closed. `integrate list` is intentionally absent because no integration registry
exists and automatic configuration discovery would cross the current explicit-target boundary.
M4e verification remains fixture-only; do not point these commands at real configuration without
an exact-target review and approval.

## M5a privacy-bounded usage storage

The private LiteLLM process loads one embedded Local AI Gateway `CustomLogger`. It accepts only the terminal
standard logging payload's public model alias, real input/output/total token counts, outcome, and a bounded
error code. Profile/provider ownership comes from a compiler-generated alias map. Prompt and response text,
tool arguments, authentication data, requester identity, upstream model/endpoint, and monetary fields are not
read or persisted.

Usage is stored in `%LOCALAPPDATA%\LocalAIGateway\usage\usage.db` using the bundled CPython standard-library
SQLite implementation. The database uses WAL and a strict schema and removes events older than one year at
most once per UTC day. Callback, mapping, database-lock, I/O, malformed payload, unknown alias, and future-schema
failures are fail-open and cannot change the model response. No new NuGet or Python package is required.

Run the focused real-runtime acceptance with:

```powershell
./scripts/test-m5a-usage-callback.ps1
```

It uses only disposable temp data and the repository's private runtime assembly, performs a real LiteLLM request
against a deterministic loopback fake upstream, checks WAL/schema/retention/fail-open/privacy, and removes its
temporary database and processes in `finally`.

## M5b usage query and WPF Tray

`aigw usage today` reads the fixed current-user usage database without starting the daemon. It aggregates requests,
outcomes, input/output/total tokens, public profile/provider/model ownership, and bounded recent error codes since
local midnight. A missing database returns zero usage without creating files.

The query reuses bundled CPython `sqlite3` with a packaged `mode=ro`/`query_only` script, a minimal environment,
five-second process timeout, strict schema/JSON validation, and no new package dependency. Run its focused WAL,
future-schema, timeout-cleanup, and product-reader acceptance with:

```powershell
./scripts/test-m5b-usage-query.ps1
```

`aigw-tray.exe` is a standalone, current-user single-instance process. In the complete package it lives at
`tray\aigw-tray.exe`; its WindowsDesktop runtime is self-contained there while it resolves the package's shared
private Python query assets from the manifest-bearing parent root. The dashboard and notification menu show daemon
status, the runtime active profile, the configured profile, and today's request/Token totals. They provide start,
stop, restart, refresh, and profile selection.

The dashboard keeps its primary actions in a fixed footer while the status and usage content scroll independently,
so the controls remain reachable at small window sizes and Windows display scaling. It uses the built-in
`Microsoft YaHei UI` family consistently and an accessible custom profile selector within the same calm neutral
visual system; the polish adds no runtime or package dependency.

Profile selection writes through the same atomic configuration manager as the CLI. If the daemon is running, the
Tray sends the existing control-plane `reload`, so the established blue-green coordinator prepares and probes the
candidate before switching traffic. If it is stopped, selection only saves configuration for the next start. The UI
receives usage only through `IUsageSummaryReader` and never queries or writes SQLite directly. Run coordinator,
state/error/cancellation, singleton-lifetime, package-layout, self-contained publish, and real EXE smoke coverage with:

```powershell
./scripts/test-m5b-tray.ps1
```

## M5c backups

Create a portable configuration-only backup at a new absolute path:

```powershell
aigw backup create --output C:\Backups\gateway-config.json
aigw backup inspect --input C:\Backups\gateway-config.json
```

`create` never overwrites an existing path. Plain backups never read Credential Manager. To include available
provider credentials, use an encrypted backup and enter the passphrase at the hidden prompt, or pipe one line through
standard input with `--passphrase-stdin`:

```powershell
aigw backup create --output C:\Backups\gateway-secrets.json --include-secrets
```

Encrypted backups use the packaged private Python runtime's Argon2id and AES-256-GCM implementation. They include
only credential targets referenced by the backed-up configuration; the installation-specific runtime client token is
never exported. Inspect first, then bind restore to both its returned SHA-256 and the current configuration revision:

```powershell
aigw backup restore --input C:\Backups\gateway-config.json `
  --expected-sha256 <inspect-hash> --expected-current-revision <current-revision> --confirm RESTORE
```

Restore writes listed provider credentials before the atomically locked configuration commit and rolls them back if
that commit fails. Credentials absent from the package are retained. Focused transaction, crypto-process, timeout,
cancellation, isolated CLI, ACL, and cleanup acceptance is:

```powershell
./scripts/test-m5c-backup.ps1
```

## M5d offline updates

Extract a newer Local AI Gateway package to a separate absolute directory, inspect it, then bind apply to the returned
manifest SHA-256 and the exact confirmation word:

```powershell
aigw update inspect --package C:\Updates\LocalAIGateway
aigw update apply --package C:\Updates\LocalAIGateway `
  --expected-manifest-sha256 <inspect-hash> --confirm UPDATE
```

Production updates require an Ed25519 signature trusted by the installed package's canonical trust store. The
`--allow-unsigned-development` switch is an explicit local-development exception and must not be used as a production
trust policy. Apply schedules a protected external worker and returns an operation ID plus receipt path; the worker
waits for the invoking CLI/updater to exit before replacing the installation. It stages and validates every manifest
file, side-load checks all executables and private Python, atomically switches the installation tree, and restores the
prior tree if post-switch health or daemon restart fails.

The focused acceptance builds the complete self-contained package, verifies its signature metadata and 11,747-file
manifest, executes a real successful update, injects a post-switch health failure, verifies automatic rollback, and
requires zero transaction/worker/test-root residue:

```powershell
./scripts/test-m5d-update.ps1
```

## M5e complete uninstall

Interactive uninstall asks separately whether to remove program files, the owned login task, explicit client
integrations, the runtime credential, provider credentials, configuration, usage, logs, and explicit backups:

```powershell
aigw uninstall
```

Automation must name all nine choices and use the exact confirmation word. Integration and backup removal never
discovers or scans external locations; every target is explicit:

```powershell
aigw uninstall --non-interactive --confirm UNINSTALL `
  --program remove --autostart remove --integrations remove `
  --runtime-credential remove --provider-credentials keep `
  --configuration remove --usage remove --logs remove --backups keep `
  --codex-cli-target C:\Path\To\aigw.config.toml
```

When program removal is selected from the installed CLI, the installed updater schedules a protected external worker,
then returns an operation ID and receipt path. Verify the receipt reports `state=completed` and `ok=true`; only then has
the worker finished the selected categories. The worker and receipt are retained under the fixed current-user
`%LOCALAPPDATA%\Temp\LocalAIGateway-Uninstall` audit root because a running Windows executable cannot safely remove its
own tree. They contain no configuration, usage rows, logs, runtime token, or provider secret. Remove only the exact
receipt and matching GUID worker directory after verifying the worker has exited; never recursively delete an
unverified Temp path.

The focused acceptance uses a random repository-owned Local AppData fixture, packages all self-contained executables,
creates only fixture integration/configuration/usage/log/backup data, invokes the installed `aigw.exe`, validates the
external receipt and recovery backup, and cleans the entire verified fixture root on success or failure:

```powershell
./scripts/test-m5e-uninstall.ps1
```

## M6a bounded Edge retries

The Edge makes one original attempt plus at most two retries for upstream 429, 502, 503, and 504 responses, and for
YARP request/timeout failures before a response starts. It does not retry 400, 401, 403, 500, client/request-body/
response-body failures, or any response after bytes have reached the client.

The rewritten JSON request body is replayed from the existing bounded in-memory stream while one immutable route
lease remains held. Without `Retry-After`, retries wait 100 ms and 200 ms. A valid delta or HTTP date is honored;
values beyond 60 seconds are passed through without retrying early. Cancellation stops a pending delay. Run the
real-loopback policy/integration tests plus a self-contained Runtime EXE smoke with:

```powershell
./scripts/test-m6a-edge-retry.ps1
```

## M6b per-target circuit breakers

Each active route revision maintains one circuit per configured `providerId + public model alias`. Five consecutive
logical requests that still end in an M6a transient category open that target for 30 seconds. Open requests return
503 with `aigw_target_circuit_open` and `Retry-After` without reaching the backend; after the interval, one half-open
request gets a complete bounded retry chain and either closes or reopens the circuit. Cancellation and client/request-
body/response-body errors are neutral, while a completed non-transient HTTP response resets the failure streak.

Control protocol v2 carries strict per-target snapshots to `aigw status`, read-only `aigw doctor`, and the Tray. The
Tray menu shows an aggregate and its dashboard lists each public target and state. Run tests, self-contained executable
smoke, two reproducible full-package builds, and manifest verification with:

```powershell
./scripts/test-m6b-circuit-breaker.ps1
```

## M6c ordered fallback

Each model keeps its existing primary `providerId + upstreamModel` and may append up to eight ordered `fallbacks`.
Legacy schema-v1 configurations without `fallbacks` remain valid. Each target must use a distinct provider for that
public alias. The Edge gives every available target its complete M6a retry chain, records the logical terminal result
in that target's M6b circuit, and moves to the next target only for a transient response-before-first-byte outcome.
Open or busy half-open targets are skipped. Non-transient responses, cancellation, body errors, and any response that
has started are never moved to another target.

```powershell
aigw model fallback-add --profile default --alias aigw/default --provider secondary --upstream fallback-model
aigw model fallback-remove --profile default --alias aigw/default --provider secondary
./scripts/test-m6c-ordered-fallback.ps1
```

## M6d weighted round robin

Set `weighted-round-robin` on an alias with at least two distinct target providers and assign each target a weight from
1 to 100. The default remains `ordered-fallback`, and omitted weights remain 1. The scheduler uses smooth weighted round
robin per immutable route revision and skips open or busy half-open circuits. A logical request selects exactly one
target: that target receives the complete M6a retry chain and M6b circuit accounting, but a terminal transient result is
not sent to another weighted target.

```powershell
aigw model weight-set --profile default --alias aigw/default --provider primary --weight 2
aigw model weight-set --profile default --alias aigw/default --provider secondary --weight 1
aigw model routing-set --profile default --alias aigw/default --strategy weighted-round-robin
./scripts/test-m6d-weighted-round-robin.ps1
```

## M6e layered request limits

Profiles, providers, and public model aliases can independently set maximum concurrency, rolling requests per minute,
and rolling tokens per minute. Every applicable layer is checked; reaching any layer returns 429 with a stable error
code and `Retry-After`. Concurrency covers the complete logical request, including retries, fallback, and streaming.
RPM is committed only when a provider is actually attempted, and the rolling state survives blue-green reload.
These limits are optional and disabled when absent. The gateway does not impose daily or monthly token quotas or
usage-threshold notifications; provider-side account quotas remain part of each provider's external API contract.

TPM is recorded from structural `usage` objects in response JSON/SSE as bytes are copied to the client. The gateway
does not buffer the full response, scan model text, or estimate tokens. For token-limited streaming Chat Completions it
forces `stream_options.include_usage=true` while preserving other options and the public model alias. One admitted
request may cross the limit; the next request is rejected.

```powershell
aigw limits profile set --profile default --concurrency 8 --rpm 120 --tpm 200000
aigw limits provider set --profile default --provider primary --concurrency 4 --rpm 60
aigw limits model set --profile default --alias aigw/default --tpm 100000
aigw limits model clear --profile default --alias aigw/default
./scripts/test-m6e-rate-limits.ps1
```

## Bounded operational logs

The production Runtime writes a deliberately minimal JSONL operational log under
`%LOCALAPPDATA%\LocalAIGateway\logs`. Entries contain only a UTC timestamp, a fixed event/level, and an optional
configuration revision. Request or response content, exception text, model names, endpoints, tokens, credentials,
and arbitrary configuration values have no logging API.

`gateway.log` rotates before crossing 10 MiB. Strictly owned rotated files are retained for 30 days and the managed
set is capped at 100 MiB; lookalike or unknown files are not removed. Current-user ACLs protect the directory and
files, reparse points are not followed, and logging failures are fail-open. Run the focused tests, real private-Runtime
composition, cleanup checks, and self-contained Runtime smoke with:

```powershell
./scripts/test-release-log-lifecycle.ps1
```

## Configuration CLI

```powershell
dotnet run --project ./src/LocalAIGateway.Cli -- --help
dotnet run --project ./src/LocalAIGateway.Cli -- limits profile --help
dotnet run --project ./src/LocalAIGateway.Cli -- update apply --help
dotnet run --project ./src/LocalAIGateway.Cli -- --version
dotnet run --project ./src/LocalAIGateway.Cli -- --json --version

# Create and complete a profile.
dotnet run --project ./src/LocalAIGateway.Cli -- profile create --id default --name "Default"
dotnet run --project ./src/LocalAIGateway.Cli -- provider add --profile default --id primary --name "Primary" --type openai-compatible --endpoint https://api.example.com/v1
dotnet run --project ./src/LocalAIGateway.Cli -- model add --profile default --alias aigw/default --provider primary --upstream upstream-model
dotnet run --project ./src/LocalAIGateway.Cli -- profile use --id default
dotnet run --project ./src/LocalAIGateway.Cli -- config validate
```

The root help lists every registered command family. Use `--help` after any command
group to list its subcommands, or after a leaf command to inspect its options and
required fields. `--json --help` also exposes `subcommands` and `options` for the
selected command. The global options `--json`, `--lang`, `--no-color`, and
`--verbose` are valid at every command level. Configuration is stored at
`%LOCALAPPDATA%\LocalAIGateway\config.json`; the previous revision is retained as
`config.json.bak`. A profile can be created as an empty draft, but it can only be
activated after it has at least one provider and model and exactly one default
model.

Remote provider endpoints require HTTPS. Plain HTTP is accepted only for the
`local-endpoint` provider type with a loopback or private IP address.

## Provider secrets

Provider API keys are stored under
`LocalAIGateway/<profile-id>/<provider-id>/api-key` in Windows Credential Manager.
They are never written to configuration JSON and there is deliberately no
plaintext command-line option. Enter a secret at the hidden prompt:

```powershell
dotnet run --project ./src/LocalAIGateway.Cli -- provider set-secret --profile default --id primary
```

For automation, pass exactly one secret line through standard input and add
`--secret-stdin`. Avoid shell constructs that echo or persist the secret in
history. Removing a provider or profile retains credentials unless the explicit
`--delete-secret` or `--delete-secrets` option is supplied.
