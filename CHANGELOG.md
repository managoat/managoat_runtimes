# Changelog

All notable changes to `managoat_runtimes` are documented here. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/). Pre-1.0, a minor bump (`0.x` to `0.y`) may
include breaking changes and says so; patch releases are always safe to take.

Merging a version bump to `main` publishes it to hex; a PR that changes what
the package ships without a bump fails the release gate.

## [Unreleased]

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
