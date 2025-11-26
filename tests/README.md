# Test Suite for provenance-context

This directory contains comprehensive tests for the `provenance-context` package.

## Test Structure

- **`conftest.py`**: Pytest fixtures providing sample RO-Crate data for testing
- **`test_crate_loading.py`**: Tests for loading crates from files and directories
- **`test_lineage.py`**: Tests for lineage queries (ancestry, descendants, file lineage)
- **`test_file_resolution.py`**: Tests for file resolution, media type detection, and file operations
- **`test_site_artifacts.py`**: Tests for site-centric artifact queries
- **`test_toon.py`**: Tests for TOON encoding (skips if toon-format not installed)
- **`test_internal_helpers.py`**: Tests for internal helper methods

## Running Tests

```bash
# Run all tests
pytest

# Run with verbose output
pytest -v

# Run specific test file
pytest tests/test_lineage.py

# Run specific test
pytest tests/test_lineage.py::test_get_file_lineage

# Run with coverage
pytest --cov=provenance_context --cov-report=html
```

## Test Coverage

The test suite includes **77 tests** covering:

- ✅ Crate loading (from_file, from_dir, init from graph)
- ✅ Index building and entity lookups
- ✅ File lineage queries
- ✅ File ancestry (upstream provenance)
- ✅ File descendants (downstream provenance)
- ✅ File entity resolution (exact match, substring match)
- ✅ Local file path resolution
- ✅ Media type detection and guessing
- ✅ Site artifacts queries
- ✅ TOON encoding (conditional on toon-format availability)
- ✅ Internal helper methods
- ✅ Error handling and edge cases

## Test Fixtures

The `conftest.py` provides several fixtures:

- `sample_crate_dir`: Minimal RO-Crate directory structure
- `sample_crate`: Loaded ProvenanceCrate from sample directory
- `multi_file_crate_dir`: Crate with multiple files for lineage testing
- `multi_file_crate`: Loaded crate with multiple files
- `site_crate_dir`: Crate with site-specific files
- `site_crate`: Loaded crate with site data

## Dependencies

Tests require:
- `pytest>=7.0.0`
- `pytest-cov>=4.0.0` (optional, for coverage)

Optional dependencies for some tests:
- `pandas` (for DataFrame tests)
- `toon-format` (for TOON encoding tests - skipped if not available)

Install test dependencies:
```bash
pip install -e ".[test]"
```

