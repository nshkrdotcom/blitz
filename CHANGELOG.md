# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-04-07

### Changed
- Enriched `Blitz.Result` with bounded `output_tail`, explicit `failure_kind`,
  and structured failure metadata used by `Blitz.Error`.
- Reworked `Blitz.Error` to render actionable failure summaries with command,
  cwd, duration, reason, and a bounded output excerpt.
- Changed timeout handling to return structured timeout failures instead of
  exiting the caller process.

### Fixed
- Preserved the last output lines for failing commands so callers do not need a
  second repro to inspect the likely root cause.
- Reported worker crashes distinctly from normal non-zero command exits.

## [0.1.0] - 2026-03-19

### Added
- Initial release.
