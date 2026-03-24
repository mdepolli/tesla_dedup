# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Waiters now receive `{:dedup_error, ref, :requester_down}` when the original requester dies, instead of hanging until the 30-second timeout
- Waiters now receive `{:dedup_error, ref, :request_cancelled}` when a request is cancelled via `Server.cancel/1`, instead of hanging
- Middleware exceptions in downstream middleware now cancel the dedup entry via `try/rescue`, preventing waiters from hanging
- Process death lookup is now O(1) via `pid_to_hashes` reverse index (was O(n) ETS scan)
- Processes tracking multiple concurrent dedup hashes no longer overwrite each other's tracking state (uses MapSet per PID)
- Monitors are now properly cleaned up with `Process.demonitor/2` on request completion

### Added

- New telemetry event `[:tesla_dedup, :abort]` emitted when a request is aborted, with `waiter_count` and `reason` measurements/metadata
- `wait_time_ms` measurement in `[:tesla_dedup, :wait]` telemetry event reporting actual wait duration

### Changed

- `Server.deduplicate/1` now uses the default 5-second GenServer timeout instead of `:infinity`, surfacing stuck GenServer issues instead of hanging indefinitely
- In-flight ETS entries now track the owner PID: `{:in_flight, [waiters], owner_pid}`

### Dependencies

- Added `credo ~> 1.7` for static analysis
- Updated `ex_doc` from `~> 0.31` to `~> 0.40`

## [0.1.0] - 2025-10-13

### Added

- Initial release of Tesla.Middleware.Dedup
- Core deduplication middleware implementing `Tesla.Middleware` behavior
- GenServer-based request tracking with ETS storage for high-performance lookups
- Automatic deduplication of concurrent identical requests based on method + URL + body
- Custom key function support via `:key_fn` option for flexible deduplication rules
- Telemetry integration with three events:
  - `[:tesla_dedup, :execute]` - First request execution
  - `[:tesla_dedup, :wait]` - Duplicate request waiting
  - `[:tesla_dedup, :cache_hit]` - Recently completed request (race condition handling)
- Automatic cleanup of completed requests after 500ms TTL
- Process monitoring to prevent memory leaks from crashed/timed-out waiters
- ETS write concurrency enabled for 2-3x throughput under high concurrent load
- Comprehensive test suite with 24 tests covering:
  - Hash generation and deduplication logic
  - High concurrency scenarios (50+ simultaneous requests)
  - Crash recovery and supervisor restart
  - Custom key functions
  - Error handling for both success and failure cases
  - Telemetry event emission
- Full documentation with architecture diagrams and usage examples
- MIT License

### Technical Details

- **Architecture**: Separation of concerns with `TeslaDedup.Server` (GenServer) and `Tesla.Middleware.Dedup` (middleware interface)
- **Performance**: O(1) lookups via ETS, optimized for concurrent writes
- **Safety**: Supervisor-managed GenServer with automatic restart on crash
- **Memory**: Completed requests automatically cleaned up to prevent leaks

[unreleased]: https://github.com/[USERNAME]/tesla_dedup/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/[USERNAME]/tesla_dedup/releases/tag/v0.1.0
