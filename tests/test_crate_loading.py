"""Tests for crate loading functionality."""

import pytest

from provenance_context import ProvenanceCrate


def test_crate_from_file(sample_crate_dir):
    """Test loading a crate from a metadata file."""
    metadata_path = sample_crate_dir / "ro-crate-metadata.json"
    crate = ProvenanceCrate.from_file(str(metadata_path))

    assert crate is not None
    assert crate.root_dir == sample_crate_dir
    assert len(crate.graph) > 0
    assert len(crate.by_id) > 0


def test_crate_from_dir(sample_crate_dir):
    """Test loading a crate from a directory."""
    crate = ProvenanceCrate.from_dir(str(sample_crate_dir))

    assert crate is not None
    assert crate.root_dir == sample_crate_dir
    assert len(crate.graph) > 0


def test_crate_init_from_graph():
    """Test initializing a crate from an in-memory graph."""
    graph = [
        {"@id": "./", "@type": "Dataset"},
        {"@id": "#file1", "@type": "File", "alternateName": "test.txt"},
    ]

    crate = ProvenanceCrate(graph)

    assert crate.graph == graph
    assert crate.root_dir is None
    assert len(crate.by_id) == 2
    assert "./" in crate.by_id
    assert "#file1" in crate.by_id


def test_crate_builds_indexes(sample_crate):
    """Test that indexes are built correctly."""
    assert len(sample_crate.by_id) > 0
    assert isinstance(sample_crate.actions, list)
    assert isinstance(sample_crate.actions_by_result, dict)
    assert isinstance(sample_crate.actions_by_input, dict)


def test_crate_actions_index(sample_crate):
    """Test that CreateActions are indexed correctly."""
    assert len(sample_crate.actions) > 0

    # Check that actions are indexed by result
    for action in sample_crate.actions:
        assert "@id" in action
        # Check that results are indexed
        for result in action.get("result", []):
            result_id = result.get("@id") if isinstance(result, dict) else result
            if result_id:
                assert result_id in sample_crate.actions_by_result


def test_crate_invalid_file(tmp_path):
    """Test loading from non-existent file raises appropriate error."""
    invalid_path = tmp_path / "nonexistent.json"

    with pytest.raises(FileNotFoundError):
        ProvenanceCrate.from_file(str(invalid_path))


def test_crate_invalid_dir(tmp_path):
    """Test loading from non-existent directory raises appropriate error."""
    invalid_dir = tmp_path / "nonexistent"

    with pytest.raises(FileNotFoundError):
        ProvenanceCrate.from_dir(str(invalid_dir))


def test_crate_without_metadata(tmp_path):
    """Test loading from directory without metadata file."""
    empty_dir = tmp_path / "empty"
    empty_dir.mkdir()

    with pytest.raises(FileNotFoundError):
        ProvenanceCrate.from_dir(str(empty_dir))
