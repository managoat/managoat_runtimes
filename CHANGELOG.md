# Changelog

All notable changes to `managoat_runtimes` are documented here. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/). Pre-1.0, a minor bump (`0.x` to `0.y`) may
include breaking changes and says so; patch releases are always safe to take.

Merging a version bump to `main` publishes it to hex; a PR that changes what
the package ships without a bump fails the release gate.

## [Unreleased]

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
