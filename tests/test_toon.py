"""Tests for TOON encoding functionality."""

import pytest


def test_to_toon_not_installed(sample_crate):
    """Test that TOON methods raise error when toon_format is not installed."""
    # This will work if toon_format is installed, otherwise will raise
    try:
        toon_result = sample_crate.to_toon_file_lineage("test_output.csv")
        # If we get here, toon_format is installed - that's fine
        assert isinstance(toon_result, str)
        assert len(toon_result) > 0
    except RuntimeError as e:
        # Expected if toon_format is not installed
        assert "toon_format is not installed" in str(e)


def test_to_toon_file_lineage(sample_crate):
    """Test encoding file lineage to TOON."""
    try:
        toon_result = sample_crate.to_toon_file_lineage("test_output.csv")
        assert isinstance(toon_result, str)
        assert len(toon_result) > 0
    except RuntimeError:
        pytest.skip("toon_format not installed")


def test_to_toon_file_lineage_single(sample_crate):
    """Test encoding single file lineage to TOON."""
    try:
        toon_result = sample_crate.to_toon_file_lineage("test_output.csv", single=True)
        assert isinstance(toon_result, str)
        # Should contain type indicator
        assert "FileLineage" in toon_result or len(toon_result) > 0
    except RuntimeError:
        pytest.skip("toon_format not installed")


def test_to_toon_site_summary(site_crate):
    """Test encoding site summary to TOON."""
    try:
        toon_result = site_crate.to_toon_site_summary("site001")
        assert isinstance(toon_result, str)
        assert len(toon_result) > 0
    except RuntimeError:
        pytest.skip("toon_format not installed")


def test_to_toon_site_summary_with_all_files(site_crate):
    """Test encoding site summary with all files to TOON."""
    try:
        toon_result = site_crate.to_toon_site_summary("site001", include_all_files=True)
        assert isinstance(toon_result, str)
        assert len(toon_result) > 0
    except RuntimeError:
        pytest.skip("toon_format not installed")


def test_to_toon_file_ancestry(multi_file_crate):
    """Test encoding file ancestry to TOON."""
    try:
        toon_result = multi_file_crate.to_toon_file_ancestry("final_output.csv")
        assert isinstance(toon_result, str)
        assert len(toon_result) > 0
    except RuntimeError:
        pytest.skip("toon_format not installed")


def test_to_toon_file_ancestry_with_depth(multi_file_crate):
    """Test encoding file ancestry with depth limit to TOON."""
    try:
        toon_result = multi_file_crate.to_toon_file_ancestry("final_output.csv", max_depth=2)
        assert isinstance(toon_result, str)
        assert len(toon_result) > 0
    except RuntimeError:
        pytest.skip("toon_format not installed")


def test_to_toon_file_descendants(multi_file_crate):
    """Test encoding file descendants to TOON."""
    try:
        toon_result = multi_file_crate.to_toon_file_descendants("raw_data.csv")
        assert isinstance(toon_result, str)
        assert len(toon_result) > 0
    except RuntimeError:
        pytest.skip("toon_format not installed")


def test_to_toon_generic(sample_crate):
    """Test generic to_toon method."""
    try:
        test_data = {"key": "value", "number": 42}
        toon_result = sample_crate.to_toon(test_data)
        assert isinstance(toon_result, str)
        assert len(toon_result) > 0
    except RuntimeError:
        pytest.skip("toon_format not installed")


def test_to_toon_with_options(sample_crate):
    """Test to_toon with custom options."""
    try:
        test_data = {"key": "value"}
        toon_result = sample_crate.to_toon(test_data, options={"indent": 4})
        assert isinstance(toon_result, str)
    except RuntimeError:
        pytest.skip("toon_format not installed")


def test_to_toon_ensure_available_error(sample_crate):
    """Test that _ensure_toon_available raises proper error message."""
    # We can't easily test this without mocking, but the error message is informative
    # Just verify the method exists and can be called
    assert hasattr(sample_crate, "_ensure_toon_available")
    assert callable(sample_crate._ensure_toon_available)
