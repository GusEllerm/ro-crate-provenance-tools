"""Tests for file resolution and media type functionality."""

from pathlib import Path

import pytest

from provenance_context import ProvenanceCrate


def test_get_file_entities_exact_match(sample_crate):
    """Test getting file entities by exact name match."""
    entities = sample_crate.get_file_entities("test_output.csv")

    assert len(entities) > 0
    assert entities[0].get("alternateName") == "test_output.csv"


def test_get_file_entities_by_id(sample_crate):
    """Test getting file entities by @id."""
    entities = sample_crate.get_file_entities("test_output.csv")

    assert len(entities) > 0
    assert "@id" in entities[0]


def test_get_file_entities_substring_match(sample_crate):
    """Test getting file entities by substring match."""
    entities = sample_crate.get_file_entities("output")

    assert len(entities) > 0
    assert any("output" in str(e.get("alternateName", "")) for e in entities)


def test_get_file_entities_nonexistent(sample_crate):
    """Test getting file entities for non-existent file."""
    entities = sample_crate.get_file_entities("nonexistent_file.csv")

    assert len(entities) == 0


def test_get_local_path(sample_crate, sample_crate_dir):
    """Test resolving file entity to local path."""
    entities = sample_crate.get_file_entities("test_output.csv")

    assert len(entities) > 0
    file_id = entities[0]["@id"]
    local_path = sample_crate.get_local_path(file_id)

    assert local_path is not None
    assert isinstance(local_path, Path)
    assert local_path.exists()
    assert local_path.name == "test_output.csv"


def test_get_local_path_with_entity_dict(sample_crate, sample_crate_dir):
    """Test resolving file entity dict directly to local path."""
    entities = sample_crate.get_file_entities("test_output.csv")

    assert len(entities) > 0
    local_path = sample_crate.get_local_path(entities[0])

    assert local_path is not None
    assert local_path.exists()


def test_get_local_path_nonexistent(sample_crate):
    """Test resolving non-existent file returns None."""
    local_path = sample_crate.get_local_path("nonexistent_file.csv")

    assert local_path is None


def test_get_local_path_no_root_dir():
    """Test that get_local_path returns None when root_dir is not set."""
    graph = [
        {"@id": "#file1", "@type": "File", "alternateName": "test.txt", "contentUrl": "test.txt"}
    ]

    crate = ProvenanceCrate(graph, root_dir=None)
    local_path = crate.get_local_path("#file1")

    assert local_path is None


def test_guess_media_type_csv():
    """Test media type guessing for CSV files."""
    file_summary = {"name": "test.csv", "encodingFormat": None}

    media_type = ProvenanceCrate.guess_media_type(file_summary)
    assert media_type == "text/csv"


def test_guess_media_type_from_encoding_format():
    """Test media type from encodingFormat field."""
    file_summary = {"name": "test.csv", "encodingFormat": "text/csv"}

    media_type = ProvenanceCrate.guess_media_type(file_summary)
    assert media_type == "text/csv"


def test_guess_media_type_json():
    """Test media type guessing for JSON files."""
    file_summary = {"name": "test.json", "encodingFormat": None}

    media_type = ProvenanceCrate.guess_media_type(file_summary)
    assert media_type == "application/json"


def test_guess_media_type_image():
    """Test media type guessing for image files."""
    for ext in [".png", ".jpg", ".jpeg", ".tif", ".tiff"]:
        file_summary = {"name": f"test{ext}", "encodingFormat": None}

        media_type = ProvenanceCrate.guess_media_type(file_summary)
        assert media_type is not None
        assert media_type.startswith("image/")


def test_is_csv():
    """Test CSV file detection."""
    file_summary = {"name": "test.csv", "encodingFormat": "text/csv"}

    assert ProvenanceCrate.is_csv(file_summary) is True


def test_is_image():
    """Test image file detection."""
    file_summary = {"name": "test.jpg", "encodingFormat": "image/jpeg"}

    assert ProvenanceCrate.is_image(file_summary) is True


def test_is_json():
    """Test JSON file detection."""
    file_summary = {"name": "test.json", "encodingFormat": "application/json"}

    assert ProvenanceCrate.is_json(file_summary) is True


def test_get_image_files(sample_crate):
    """Test getting all image files from crate."""
    # Add an image file to the graph for testing
    image_entity = {
        "@id": "test_image.jpg",
        "@type": "File",
        "alternateName": "test_image.jpg",
        "encodingFormat": "image/jpeg",
    }

    sample_crate.graph.append(image_entity)
    sample_crate._build_indexes()

    images = sample_crate.get_image_files()
    assert len(images) > 0
    assert any("image" in str(img.get("encodingFormat", "")).lower() for img in images)


def test_open_as_bytes(sample_crate, sample_crate_dir):
    """Test opening a file as bytes."""
    entities = sample_crate.get_file_entities("test_output.csv")
    if entities:
        content = sample_crate.open_as_bytes("test_output.csv")
        assert content is not None
        assert isinstance(content, bytes)
        assert len(content) > 0


def test_open_as_text(sample_crate, sample_crate_dir):
    """Test opening a file as text."""
    entities = sample_crate.get_file_entities("test_output.csv")
    if entities:
        content = sample_crate.open_as_text("test_output.csv")
        assert content is not None
        assert isinstance(content, str)
        assert len(content) > 0


def test_open_as_text_nonexistent(sample_crate):
    """Test opening non-existent file returns None."""
    content = sample_crate.open_as_text("nonexistent_file.csv")
    assert content is None


def test_open_as_bytes_nonexistent(sample_crate):
    """Test opening non-existent file as bytes returns None."""
    content = sample_crate.open_as_bytes("nonexistent_file.csv")
    assert content is None


def test_open_as_dataframe(sample_crate, sample_crate_dir):
    """Test opening a CSV file as DataFrame (requires pandas)."""
    pytest.importorskip("pandas")

    entities = sample_crate.get_file_entities("test_output.csv")
    if entities:
        df = sample_crate.open_as_dataframe("test_output.csv")
        assert df is not None
        assert hasattr(df, "columns")
        assert len(df.columns) > 0


def test_open_as_dataframe_invalid_type(sample_crate, sample_crate_dir):
    """Test that opening non-CSV as DataFrame raises error."""
    pytest.importorskip("pandas")

    # Create a JSON file
    json_file = sample_crate_dir / "test.json"
    json_file.write_text('{"key": "value"}')

    # Add it to the crate graph
    json_entity = {
        "@id": "test.json",
        "@type": "File",
        "alternateName": "test.json",
        "encodingFormat": "application/json",
        "contentUrl": "test.json",
    }
    sample_crate.graph.append(json_entity)
    sample_crate._build_indexes()

    with pytest.raises(ValueError, match="not a CSV"):
        sample_crate.open_as_dataframe("test.json")
