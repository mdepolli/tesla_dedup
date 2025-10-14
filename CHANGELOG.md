# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
