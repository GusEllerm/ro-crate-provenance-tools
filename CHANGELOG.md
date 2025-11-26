# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-01-XX

### Added
- Initial release of provenance-context
- `ProvenanceCrate` class for querying RO-Crate provenance metadata
- File lineage queries (`get_file_lineage`)
- File ancestry queries (`get_file_ancestry`) 
- File descendants queries (`get_file_descendants`)
- Site artifacts queries (`get_site_artifacts`)
- TOON encoding support for LLM prompts
- File resolution and media type detection
- Comprehensive test suite (77 tests)

## [0.2.0] - 2025-11-27

### Changed
- Updated README.md to include installation instructions
- toon no longer required for installation due to not being available on PyPI

[Unreleased]: https://github.com/GusEllerm/ro-crate-provenance-tools/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/GusEllerm/ro-crate-provenance-tools/releases/tag/v0.1.0
[0.2.0]: https://github.com/GusEllerm/ro-crate-provenance-tools/releases/tag/v0.2.0
