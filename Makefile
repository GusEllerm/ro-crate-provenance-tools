.PHONY: help install install-dev test test-cov lint format clean build publish-check publish

help:
	@echo "Available commands:"
	@echo "  make install       - Install package in editable mode"
	@echo "  make install-dev   - Install with dev dependencies"
	@echo "  make test          - Run tests"
	@echo "  make test-cov      - Run tests with coverage"
	@echo "  make lint          - Run linter (ruff)"
	@echo "  make format        - Format code (ruff)"
	@echo "  make clean         - Remove build artifacts"
	@echo "  make build         - Build distribution packages"
	@echo "  make publish-check - Check package before publishing"
	@echo "  make publish       - Publish to PyPI (requires credentials)"

install:
	pip install -e .

install-dev:
	pip install -e ".[dev,test]"

test:
	pytest tests/ -v

test-cov:
	pytest tests/ --cov=provenance_context --cov-report=html --cov-report=term

lint:
	python -m ruff check provenance_context/ tests/
	python -m ruff format --check provenance_context/ tests/

format:
	python -m ruff format provenance_context/ tests/
	python -m ruff check --fix provenance_context/ tests/

clean:
	rm -rf build/
	rm -rf dist/
	rm -rf *.egg-info
	rm -rf .pytest_cache
	rm -rf .ruff_cache
	find . -type d -name __pycache__ -exec rm -r {} +
	find . -type f -name "*.pyc" -delete

build:
	python -m build

publish-check: clean build
	twine check dist/*

publish: publish-check
	@echo "Publishing to PyPI..."
	twine upload dist/*

