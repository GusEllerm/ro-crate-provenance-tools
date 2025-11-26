# Library Management Guide

Complete guide for managing `provenance-context` development and releases.

## 📋 Overview

This project uses:
- **GitHub** for version control and releases
- **PyPI** for package distribution
- **GitHub Actions** for CI/CD automation
- **Semantic Versioning** for version management

## 🚀 Quick Start

### Initial Setup (One-time)

1. **Set up PyPI account** (if not done):
   - Create account: https://pypi.org/account/register/
   - Create API token: https://pypi.org/manage/account/token/
   - Token format: `pypi-xxxxx...`

2. **Configure GitHub Actions** (for automatic publishing):
   - Go to: Settings → Secrets and variables → Actions
   - Add repository secret: `PYPI_API_TOKEN` with your PyPI token
   - This enables automatic publishing on release

3. **Local development setup**:
   ```bash
   git clone <your-repo-url>
   cd cwltool_provenance_tools
   make install-dev
   ```

## 🔄 Daily Development Workflow

### 1. Make Changes

```bash
# Create feature branch
git checkout -b feature/new-feature

# Make changes, write code
# Run tests
make test

# Format code
make format

# Commit with conventional commit message
git add .
git commit -m "feat: add new feature"
git push origin feature/new-feature
```

### 2. Create Pull Request

- Open PR on GitHub
- CI will automatically run tests
- Review and merge when ready

### 3. Merge to Main

- Changes merged to `main`
- CI runs tests on all platforms

## 📦 Release Process

### Step 1: Prepare Release

```bash
# Update CHANGELOG.md with new changes
# Update version in pyproject.toml
./scripts/bump-version.sh 0.2.0
```

Or manually:
```toml
# pyproject.toml
version = "0.2.0"
```

### Step 2: Commit and Tag

```bash
git add pyproject.toml CHANGELOG.md
git commit -m "chore: bump version to 0.2.0"
git tag -a v0.2.0 -m "Release version 0.2.0"
git push origin main
git push origin v0.2.0
```

### Step 3: Create GitHub Release

1. Go to: https://github.com/GusEllerm/ro-crate-provenance-tools/releases
2. Click "Draft a new release"
3. Select tag: `v0.2.0`
4. Title: `v0.2.0`
5. Description: Copy from CHANGELOG.md
6. Click "Publish release"

### Step 4: Automatic Publishing

GitHub Actions will:
- ✅ Build the package
- ✅ Check package validity
- ✅ Publish to PyPI automatically
- ✅ Create distribution files

### Step 5: Verify

```bash
# Wait a few minutes, then verify on PyPI
# Visit: https://pypi.org/project/provenance-context/

# Test installation
pip install --upgrade provenance-context
```

## make commands

### dev

```bash
make install-dev    # Install with dev dependencies
make test           # Run tests
make test-cov       # Run tests with coverage
make lint           # Check code quality
make format         # Format code
make clean          # Clean build artifacts
```

### build

```bash
make build          # Build distribution packages
make publish-check  # Check package before publishing
```

## Versioning 


### Current Version

Version is in `pyproject.toml`:
```toml
[project]
version = "0.1.0"
```

### Bumping Version

**Automatic (recommended)**:
```bash
./scripts/bump-version.sh 0.2.0
```

**Manual**:
1. Edit `pyproject.toml`
2. Update version string
3. Commit and tag

## 🧪 Testing Strategy

- **All PRs**: Tests run automatically via GitHub Actions
- **Before release**: All tests must pass
- **Test coverage**: Run `make test-cov` to check

## 📝 Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation
- `test:` - Tests
- `chore:` - Maintenance
- `refactor:` - Code refactoring

Examples:
```
feat: add support for JSON export
fix: handle missing contentUrl gracefully
docs: update README with examples
chore: bump version to 0.2.0
```

## 🚨 Troubleshooting

### Tests failing locally
```bash
make clean
make install-dev
make test
```

### PyPI publish fails
- Check API token is valid
- Ensure version number is unique (not already on PyPI)
- Check package name availability

### Version conflicts
- Ensure version in `pyproject.toml` matches git tag
- Check PyPI for existing version numbers

## 📚 Additional Resources

- **Development**: See [DEVELOPMENT.md](DEVELOPMENT.md)
- **Tests**: See [tests/README.md](tests/README.md)
- **User docs**: See [README.md](README.md)

## 🔗 Links

- **GitHub**: https://github.com/GusEllerm/ro-crate-provenance-tools
- **PyPI**: https://pypi.org/project/provenance-context/
- **Issues**: https://github.com/GusEllerm/ro-crate-provenance-tools/issues

