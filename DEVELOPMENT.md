# Development Guide

Quick reference for day-to-day development of `provenance-context`.

## env

```bash
# Clone the repository
git clone https://github.com/GusEllerm/ro-crate-provenance-tools.git
cd cwltool_provenance_tools

# Install in editable mode with dev dependencies
make install-dev
# or
pip install -e ".[dev,test]"
```

### testing

```bash
# Run all tests
make test
# or
pytest tests/

# Run with coverage
make test-cov

# Run specific test file
pytest tests/test_lineage.py

# Run specific test
pytest tests/test_lineage.py::test_get_file_lineage
```

### CQ

```bash
# Format code
make format

# Check formatting
make lint

# Clean build artifacts
make clean
```

### build

```bash
# Build distribution packages
make build

# Check package before publishing
make publish-check
```

## Version Management

Version is stored in `pyproject.toml`. To bump:

```bash
# Using the script (recommended)
./scripts/bump-version.sh 0.2.0
```

Follow [Semantic Versioning](https://semver.org/):
- **MAJOR.MINOR.PATCH** (e.g., 1.2.3)
- **MAJOR**: Breaking changes
- **MINOR**: New features, backwards compatible
- **PATCH**: Bug fixes, backwards compatible

The version is stored in `pyproject.toml` under `[project] version`.

## publishing

See [RELEASE.md](RELEASE.md) for detailed release process.

Quick version:
1. Update version in `pyproject.toml`
2. Commit and push
3. Create git tag
4. Create GitHub release (auto-publishes to PyPI)
