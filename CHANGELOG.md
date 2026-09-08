# Changelog

All notable changes to `managoat_runtimes` are documented here. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/). Pre-1.0, a minor bump (`0.x` to `0.y`) may
include breaking changes and says so; patch releases are always safe to take.

Merging a version bump to `main` publishes it to hex; a PR that changes what
the package ships without a bump fails the release gate.

## [Unreleased]

## [0.4.2]

- Add `ACP.bootstrap_command/3` to install the pinned adapter and exec its argv
  within one provider command. Setup cannot consume protocol stdin or write to
  protocol stdout; a failed install prevents adapter startup. Hosts own tracking
  and termination. Existing standalone installation remains available.

## [0.4.1]

- Accept Sandbox 0.3 alongside 0.2 so hosts can use its optional confirmed session-termination API.

## [0.4.0] - 2026-09-07

### Added

- `ACP.execution_limits/2` validates typed Claude SDK limits against the actual
  runtime; unsupported runtimes and malformed options are refused. Hosts retain
  ownership of account ceilings, durable reservations and process lifecycle.

### Changed

- Require `managoat_acp ~> 0.4.0` for typed limits. Consumers must handle its
  fail-closed `unknown` stop reason for malformed prompt responses.

## [0.3.4] - 2026-09-07

### Added

- `Managoat.Runtimes.Claude.prepare_sandbox/3` warms the CLI's model list
  before the host's first session. The Claude Code binary bundled in the
  adapter's SDK learns an org's "additional models" (Fable among them) from a
  fetch it makes after a session has started, and caches the answer in
  `~/.claude.json` for the *next* launch — so the first session in a fresh
  sandbox never listed Fable and refused `claude-fable-5-1` at
  `session/set_config_option`, on every adapter version, while the second
  session in the same sandbox accepted it. The warm-up opens one prompt-less
  ACP session through the pinned adapter and waits for the cache (under three
  seconds measured; bounded at 30, which is also the whole cost of a
  credential the org refuses). Best-effort: a cache that stays cold is
  logged and provisioning continues, and nothing runs without a credential in
  the env. Recorded as `:claude_model_list_warmup` in `Managoat.Runtimes.Quirks`
  with the re-probe and the deletion condition. Hosts that dispatch through
  `Managoat.Runtimes.prepare_sandbox/4` or their own `function_exported?/3`
  guard pick it up with no change; hosts that skip claude's `prepare_sandbox`
  by name now have a reason not to.

## [0.3.3] - 2026-09-07

### Changed

- Pin `@agentclientprotocol/claude-agent-acp` at 0.75.1, up from 0.66.0. The
  adapter's model list is whatever the Claude Code binary bundled in its SDK
  dependency reports, and that binary refuses `claude-fable-5-1` below
  2.1.255: 0.66.0 bundles SDK 0.3.220 (CLI 2.1.220), 0.75.1 bundles SDK
  0.3.257 (CLI 2.1.257). 0.75.1's `session/set_config_option` also resolves a
  full model id onto the alias row the CLI advertises, which 0.66.0's exact
  match did not. Existing installations are corrected by the version check
  during installation; running connections keep their process until reopened.
  Measured with real turns on haiku and claude-fable-5-1: the prompt result's
  `usage` keeps the protocol shape `Managoat.ACP.Usage` reads, and the two
  notifications new since 0.66 (`_auth/status_update`, `usage_update`) fall
  through the peer's unknown-notification clause.
- `:claude_mcp_via_files` re-probed on the new pin, as its entry asks. A stdio
  server passed only over `session/new` now reaches the model, and a server
  named on both paths is registered once, so the file-based provisioning is
  kept for now rather than deleted: `http`/`sse` entries over the
  session-scoped path are not yet measured, and that is the shape a hosted
  connector takes. The entry records what was measured and what is left.

## [0.3.2] - 2026-09-07

### Changed

- Accept Managoat.ACP 0.3.x, which preserves adapter accounting metadata.
  The runtime library uses its unchanged protocol initialization API. Existing
  0.1.x and 0.2.x consumers remain supported; adapter pins are unchanged.

## [0.3.1]

### Fixed

- Pin Codex ACP to 1.10.0, which bundles Codex ^0.153.3. The previous adapter
  bundled 0.147.0 on the affected Fountain sandbox and did not advertise
  GPT-6 Astra. Existing installations are corrected by the version check
  during installation; running connections keep their process until reopened.
- Recognize the package-prefixed `codex-acp --version` output, so checking an
  already installed pin does not run npm again.
- Allow `managoat_acp` 0.2 alongside 0.1.1 and later 0.1 patches. Hosts can
  adopt strict model selection without a dependency override; the protocol
  and usage helpers consumed by this package are compatible with both.


## [0.3.0] - 2026-09-03

### Added

- `Managoat.Runtimes.default_env/3`, `write_config/3` and `prepare_sandbox/4`
  dispatch an optional callback and fall back to its documented no-op, and
  `implements?/3` answers the same question for `build_command/5`, which has
  no default to fall back to. All four call `Code.ensure_loaded?/1` first.
  `function_exported?/3` alone answers `false` for a module that is merely not
  loaded yet — the normal state under an escript or a release — so the obvious
  guard silently drops callbacks the runtime does implement. It cost one host
  its whole inference credential env, on a provisioning run that reported every
  stage green (#7). The README and the moduledoc name the trap where a host
  looks for it.

## [0.2.1] - 2026-09-03

### Changed

- Raised the package's coverage gate from 90% to 96% after adding contract
  coverage for model translation, empty skill sets, pre-normalized MCP headers,
  adapter lookup fallbacks, and configuration no-ops.

## [0.2.0] - 2026-09-03

### Changed

- Takes `managoat_sandbox ~> 0.2.0`, where a command stream that closes
  without an exit frame is `{:error, %{ref: ref}, :closed_before_exit}`
  rather than a synthesised `{:exit, %{ref: ref}, 0}`
  (managoat/managoat_sandbox#4).
- `Managoat.Runtimes.Codex.prepare_sandbox/3` answers that frame. `codex
  login --with-api-key` is driven over stdin and waited on for its exit, and
  the old synthesised zero landed on the success clause: a login whose
  transport went away was reported as one that worked, and provisioning
  carried on with a sandbox that had no `~/.codex/auth.json`. It is now
  `{:error, {:codex_login_transport, reason}}` — and arrives at once rather
  than after the 30-second wait for a frame that had already been sent.

## [0.1.3] - 2026-09-03

### Changed

- `:gemini_usage_in_meta_quota`'s `measured_against` now records the whole
  range the shape was checked over — gemini-cli 0.53.0, 0.56.0 and 0.59 return
  it byte-identically. Read against 0.59 alone it invited the question of
  whether it applied to the 0.53–0.56 versions
  `:gemini_session_store_consolidation` was measured against, which is the
  band a sprite base image actually ships. It does. No behaviour change.

## [0.1.2] - 2026-09-03

### Added

- `Quirks` records `:gemini_usage_in_meta_quota`. gemini leaves ACP's
  `PromptResponse.usage` empty and reports the turn's tokens under a vendor
  extension at `_meta.quota.token_count`, so a host billing from that figure
  billed nothing for gemini (BinaryBourbon/fountain#1459). The workaround is
  `Managoat.ACP.Usage.from_meta_quota/1`, released in managoat_acp 0.1.1, and
  the entry carries the upstream issue and what would delete it.

### Changed

- `managoat_acp` is pinned `~> 0.1.1`. The quirk above names a function added
  in that release, and the registry's guardrail asserts it exists — an older
  managoat_acp now fails the suite rather than the billing.

## [0.1.1] - 2026-09-03

### Fixed

- opencode on a `google/` model now gets its key as
  `GOOGLE_GENERATIVE_AI_API_KEY`, the name `@ai-sdk/google` reads, instead of
  `GEMINI_API_KEY`, which opencode does not read at all. Every opencode turn
  on a Gemini model failed with `Authentication required: provider
  authentication required`; this was true for a tenant's own key as much as a
  platform one (BinaryBourbon/fountain#1460).

## [0.1.0] - 2026-09-02

### Added

- Extracted from Fountain (BinaryBourbon/fountain#1387).
