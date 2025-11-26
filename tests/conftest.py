"""Pytest configuration and fixtures for provenance-context tests."""

import json

import pytest

from provenance_context import ProvenanceCrate


@pytest.fixture
def sample_crate_dir(tmp_path):
    """Create a minimal RO-Crate directory structure for testing."""
    crate_dir = tmp_path / "test_crate"
    crate_dir.mkdir()

    # Create a simple test file
    test_file = crate_dir / "test_output.csv"
    test_file.write_text("col1,col2\n1,2\n3,4\n")

    # Create ro-crate-metadata.json
    metadata = {
        "@context": [
            "https://w3id.org/ro/crate/1.1/context",
            "https://w3id.org/ro/terms/workflow-run",
        ],
        "@graph": [
            {"@id": "./", "@type": "Dataset", "name": "Test Crate"},
            {
                "@id": "#action1",
                "@type": ["CreateAction", "Action"],
                "name": "Run of test workflow",
                "startTime": "2024-01-01T00:00:00Z",
                "endTime": "2024-01-01T01:00:00Z",
                "instrument": {"@id": "#tool1"},
                "object": [{"@id": "#input1"}, {"@id": "#param1"}],
                "result": [{"@id": "test_output.csv"}],
            },
            {
                "@id": "#tool1",
                "@type": "SoftwareApplication",
                "name": "test-tool",
                "input": [{"@id": "#input1"}],
                "output": [{"@id": "test_output.csv"}],
            },
            {
                "@id": "#input1",
                "@type": "File",
                "alternateName": "input.csv",
                "encodingFormat": "text/csv",
                "sha1": "abc123",
            },
            {
                "@id": "test_output.csv",
                "@type": "File",
                "alternateName": "test_output.csv",
                "encodingFormat": "text/csv",
                "sha1": "def456",
                "contentUrl": "test_output.csv",
            },
            {"@id": "#param1", "@type": "PropertyValue", "name": "site_id", "value": "site001"},
            {"@id": "#dataset1", "@type": "Dataset", "alternateName": "site001/"},
            {
                "@id": "site001_output.json",
                "@type": "File",
                "alternateName": "site001_output.json",
                "encodingFormat": "application/json",
                "sha1": "ghi789",
            },
        ],
    }

    metadata_file = crate_dir / "ro-crate-metadata.json"
    with metadata_file.open("w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2)

    return crate_dir


@pytest.fixture
def sample_crate(sample_crate_dir):
    """Load a ProvenanceCrate from the sample crate directory."""
    return ProvenanceCrate.from_dir(str(sample_crate_dir))


@pytest.fixture
def multi_file_crate_dir(tmp_path):
    """Create a crate with multiple files and actions for testing lineage."""
    crate_dir = tmp_path / "multi_crate"
    crate_dir.mkdir()

    # Create test files
    (crate_dir / "raw_data.csv").write_text("raw\n1\n")
    (crate_dir / "processed_data.csv").write_text("processed\n2\n")
    (crate_dir / "final_output.csv").write_text("final\n3\n")

    metadata = {
        "@context": [
            "https://w3id.org/ro/crate/1.1/context",
            "https://w3id.org/ro/terms/workflow-run",
        ],
        "@graph": [
            {"@id": "./", "@type": "Dataset"},
            {
                "@id": "raw_data.csv",
                "@type": "File",
                "alternateName": "raw_data.csv",
                "encodingFormat": "text/csv",
            },
            {
                "@id": "#action1",
                "@type": "CreateAction",
                "name": "Process raw data",
                "object": [{"@id": "raw_data.csv"}],
                "result": [{"@id": "processed_data.csv"}],
                "instrument": {"@id": "#tool1"},
            },
            {
                "@id": "processed_data.csv",
                "@type": "File",
                "alternateName": "processed_data.csv",
                "encodingFormat": "text/csv",
                "contentUrl": "processed_data.csv",
            },
            {
                "@id": "#action2",
                "@type": "CreateAction",
                "name": "Generate final output",
                "object": [{"@id": "processed_data.csv"}],
                "result": [{"@id": "final_output.csv"}],
                "instrument": {"@id": "#tool2"},
            },
            {
                "@id": "final_output.csv",
                "@type": "File",
                "alternateName": "final_output.csv",
                "encodingFormat": "text/csv",
                "contentUrl": "final_output.csv",
            },
            {"@id": "#tool1", "@type": "SoftwareApplication", "name": "process-tool"},
            {"@id": "#tool2", "@type": "SoftwareApplication", "name": "finalize-tool"},
        ],
    }

    metadata_file = crate_dir / "ro-crate-metadata.json"
    with metadata_file.open("w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2)

    return crate_dir


@pytest.fixture
def multi_file_crate(multi_file_crate_dir):
    """Load a ProvenanceCrate with multiple files."""
    return ProvenanceCrate.from_dir(str(multi_file_crate_dir))


@pytest.fixture
def site_crate_dir(tmp_path):
    """Create a crate with site-specific files for testing site artifacts."""
    crate_dir = tmp_path / "site_crate"
    crate_dir.mkdir()

    metadata = {
        "@context": [
            "https://w3id.org/ro/crate/1.1/context",
            "https://w3id.org/ro/terms/workflow-run",
        ],
        "@graph": [
            {"@id": "./", "@type": "Dataset"},
            {
                "@id": "#action1",
                "@type": "CreateAction",
                "name": "Process site001",
                "object": [{"@id": "#param_site001"}, {"@id": "#dataset_site001"}],
                "result": [{"@id": "site001_output.csv"}],
                "instrument": {"@id": "#tool1"},
            },
            {
                "@id": "#param_site001",
                "@type": "PropertyValue",
                "name": "site_id",
                "value": "site001",
            },
            {"@id": "#dataset_site001", "@type": "Dataset", "alternateName": "site001/"},
            {
                "@id": "site001_output.csv",
                "@type": "File",
                "alternateName": "site001_output.csv",
                "encodingFormat": "text/csv",
                "sha1": "site001hash",
            },
            {"@id": "#tool1", "@type": "SoftwareApplication", "name": "site-processor"},
        ],
    }

    metadata_file = crate_dir / "ro-crate-metadata.json"
    with metadata_file.open("w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2)

    return crate_dir


@pytest.fixture
def site_crate(site_crate_dir):
    """Load a ProvenanceCrate with site-specific data."""
    return ProvenanceCrate.from_dir(str(site_crate_dir))
