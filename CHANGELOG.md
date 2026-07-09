# Changelog

## [1.0.5] - 2026-07-09

### Fixed

- Pin local and fallback runtime builds to the same immutable `gpf-geocodeur` commit as the GHCR image.

## [1.0.4] - 2026-07-09

### Changed

- Update the proxy base image from nginx 1.31.0 to 1.31.2.
- Update the GitHub Actions checkout action from v6 to v7.
- Pin the upstream `gpf-geocodeur` runtime source to an immutable commit for reproducible GHCR builds.
- Generate release notes without repeating the first-release announcement.

[1.0.5]: https://github.com/jbjardine/GeoDock/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/jbjardine/GeoDock/compare/v1.0.3...v1.0.4
