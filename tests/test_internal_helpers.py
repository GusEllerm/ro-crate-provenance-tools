"""Tests for internal helper methods."""

from provenance_context import ProvenanceCrate


def test_has_type():
    """Test _has_type helper method."""
    entity_string_type = {"@type": "File"}
    assert ProvenanceCrate._has_type(entity_string_type, "File") is True
    assert ProvenanceCrate._has_type(entity_string_type, "Dataset") is False

    entity_list_type = {"@type": ["File", "CreativeWork"]}
    assert ProvenanceCrate._has_type(entity_list_type, "File") is True
    assert ProvenanceCrate._has_type(entity_list_type, "CreativeWork") is True
    assert ProvenanceCrate._has_type(entity_list_type, "Dataset") is False


def test_summarise_file():
    """Test file summarisation helper."""
    file_entity = {
        "@id": "#file1",
        "@type": "File",
        "alternateName": "test.csv",
        "sha1": "abc123",
        "encodingFormat": "text/csv",
    }

    summary = ProvenanceCrate._summarise_file(file_entity)

    assert summary["id"] == "#file1"
    assert summary["name"] == "test.csv"
    assert summary["sha1"] == "abc123"
    assert summary["encodingFormat"] == "text/csv"


def test_summarise_dataset():
    """Test dataset summarisation helper."""
    dataset_entity = {"@id": "#dataset1", "@type": "Dataset", "alternateName": "test_dataset"}

    summary = ProvenanceCrate._summarise_dataset(dataset_entity)

    assert summary["id"] == "#dataset1"
    assert summary["name"] == "test_dataset"


def test_summarise_param():
    """Test parameter summarisation helper."""
    param_entity = {
        "@id": "#param1",
        "@type": "PropertyValue",
        "name": "site_id",
        "value": "site001",
    }

    summary = ProvenanceCrate._summarise_param(param_entity)

    assert summary["id"] == "#param1"
    assert summary["name"] == "site_id"
    assert summary["value"] == "site001"


def test_summarise_action():
    """Test action summarisation helper."""
    action_entity = {
        "@id": "#action1",
        "@type": "CreateAction",
        "name": "Test Action",
        "startTime": "2024-01-01T00:00:00Z",
        "endTime": "2024-01-01T01:00:00Z",
    }

    summary = ProvenanceCrate._summarise_action(action_entity)

    assert summary["id"] == "#action1"
    assert summary["name"] == "Test Action"
    assert summary["startTime"] == "2024-01-01T00:00:00Z"
    assert summary["endTime"] == "2024-01-01T01:00:00Z"


def test_summarise_tool():
    """Test tool summarisation helper."""
    tool_entity = {
        "@id": "#tool1",
        "@type": "SoftwareApplication",
        "name": "test-tool",
        "input": [{"@id": "#input1"}],
        "output": [{"@id": "#output1"}],
    }

    summary = ProvenanceCrate._summarise_tool(tool_entity)

    assert summary is not None
    assert summary["id"] == "#tool1"
    assert summary["name"] == "test-tool"
    assert "inputs" in summary
    assert "outputs" in summary


def test_summarise_tool_none():
    """Test tool summarisation with None input."""
    summary = ProvenanceCrate._summarise_tool(None)
    assert summary is None


def test_find_files_by_altname(sample_crate):
    """Test finding files by alternate name pattern."""
    files = sample_crate._find_files_by_altname("output")

    assert isinstance(files, list)
    # Should find test_output.csv
    assert len(files) > 0
    assert all(sample_crate._has_type(f, "File") for f in files)


def test_find_files_by_altname_no_match(sample_crate):
    """Test finding files with no match."""
    files = sample_crate._find_files_by_altname("nonexistent_pattern")

    assert isinstance(files, list)
    assert len(files) == 0


def test_build_indexes(sample_crate):
    """Test that indexes are built correctly."""
    # Verify all entities are indexed
    assert len(sample_crate.by_id) == len(sample_crate.graph)

    # Verify actions are collected
    action_count = sum(1 for e in sample_crate.graph if sample_crate._has_type(e, "CreateAction"))
    assert len(sample_crate.actions) == action_count

    # Verify indexes are dictionaries
    assert isinstance(sample_crate.actions_by_result, dict)
    assert isinstance(sample_crate.actions_by_input, dict)


def test_build_indexes_result_mapping(multi_file_crate):
    """Test that actions_by_result maps correctly."""
    # Find an action that produces a result
    for action in multi_file_crate.actions:
        for result in action.get("result", []):
            result_id = result.get("@id") if isinstance(result, dict) else result
            if result_id:
                assert result_id in multi_file_crate.actions_by_result
                assert action["@id"] in multi_file_crate.actions_by_result[result_id]


def test_build_indexes_input_mapping(multi_file_crate):
    """Test that actions_by_input maps correctly."""
    # Find an action that uses an input
    for action in multi_file_crate.actions:
        for obj in action.get("object", []):
            obj_id = obj.get("@id") if isinstance(obj, dict) else obj
            if obj_id:
                assert obj_id in multi_file_crate.actions_by_input
                assert action["@id"] in multi_file_crate.actions_by_input[obj_id]
