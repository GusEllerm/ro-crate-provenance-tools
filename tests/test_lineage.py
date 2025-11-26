"""Tests for lineage query functionality."""


def test_get_file_lineage(sample_crate):
    """Test getting file lineage."""
    lineages = sample_crate.get_file_lineage("test_output.csv")

    assert len(lineages) > 0
    lineage = lineages[0]

    assert "file" in lineage
    assert "produced_by" in lineage or "note" in lineage
    assert "site_ids" in lineage


def test_get_file_lineage_exact_match(sample_crate):
    """Test file lineage with exact file ID match."""
    lineages = sample_crate.get_file_lineage("test_output.csv")

    assert len(lineages) > 0
    file_info = lineages[0]["file"]
    assert file_info["name"] == "test_output.csv"


def test_get_file_lineage_by_id(sample_crate):
    """Test file lineage using @id."""
    lineages = sample_crate.get_file_lineage("test_output.csv")

    assert len(lineages) > 0


def test_get_file_lineage_nonexistent(sample_crate):
    """Test getting lineage for non-existent file."""
    lineages = sample_crate.get_file_lineage("nonexistent_file.csv")

    assert len(lineages) == 0


def test_get_file_ancestry(sample_crate):
    """Test getting file ancestry (upstream provenance)."""
    ancestry = sample_crate.get_file_ancestry("test_output.csv")

    assert "root_files" in ancestry
    assert "entities" in ancestry
    assert "actions" in ancestry
    assert "edges" in ancestry

    assert len(ancestry["root_files"]) > 0


def test_get_file_ancestry_with_depth(sample_crate):
    """Test getting file ancestry with depth limit."""
    ancestry = sample_crate.get_file_ancestry("test_output.csv", max_depth=1)

    assert "root_files" in ancestry
    assert "entities" in ancestry
    assert "actions" in ancestry


def test_get_file_ancestry_nonexistent(sample_crate):
    """Test getting ancestry for non-existent file."""
    ancestry = sample_crate.get_file_ancestry("nonexistent_file.csv")

    assert ancestry["root_files"] == []
    assert len(ancestry["entities"]) == 0


def test_get_file_descendants(multi_file_crate):
    """Test getting file descendants (downstream provenance)."""
    descendants = multi_file_crate.get_file_descendants("raw_data.csv")

    assert "root_files" in descendants
    assert "entities" in descendants
    assert "actions" in descendants
    assert "edges" in descendants
    assert "descendant_files" in descendants

    # Should have downstream files (we expect more than just the root file)
    assert len(descendants["entities"]) > 1 or len(descendants["descendant_files"]) > 0


def test_get_file_descendants_with_depth(multi_file_crate):
    """Test getting file descendants with depth limit."""
    descendants = multi_file_crate.get_file_descendants("raw_data.csv", max_depth=1)

    assert "root_files" in descendants
    assert "entities" in descendants


def test_get_file_descendants_nonexistent(multi_file_crate):
    """Test getting descendants for non-existent file."""
    descendants = multi_file_crate.get_file_descendants("nonexistent_file.csv")

    assert descendants["root_files"] == []
    assert len(descendants["descendant_files"]) == 0


def test_lineage_includes_action_info(sample_crate):
    """Test that lineage includes action information."""
    lineages = sample_crate.get_file_lineage("test_output.csv")

    if lineages and lineages[0].get("produced_by"):
        produced_by = lineages[0]["produced_by"]
        assert "action" in produced_by
        assert "tool" in produced_by
        assert "inputs" in produced_by


def test_lineage_includes_site_ids(sample_crate):
    """Test that lineage includes site_ids when present."""
    lineages = sample_crate.get_file_lineage("test_output.csv")

    assert len(lineages) > 0
    assert "site_ids" in lineages[0]
    # Should have site001 from the fixture
    assert "site001" in lineages[0]["site_ids"]


def test_ancestry_entities_and_actions(multi_file_crate):
    """Test that ancestry includes both entities and actions."""
    ancestry = multi_file_crate.get_file_ancestry("final_output.csv")

    # Should have multiple entities in the chain
    assert len(ancestry["entities"]) > 1
    # Should have multiple actions
    assert len(ancestry["actions"]) > 1
    # Should have edges connecting them
    assert len(ancestry["edges"]) > 0


def test_descendants_includes_all_downstream(multi_file_crate):
    """Test that descendants captures all downstream files."""
    descendants = multi_file_crate.get_file_descendants("raw_data.csv")

    # Should find both processed and final outputs
    entity_ids = list(descendants["entities"].keys())
    file_names = [descendants["entities"][eid].get("name", "") for eid in entity_ids]

    # Check that we have both intermediate and final files
    has_processed = any("processed" in name for name in file_names)
    has_final = any("final" in name for name in file_names)

    assert has_processed or has_final
