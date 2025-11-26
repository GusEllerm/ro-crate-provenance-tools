"""Tests for site artifacts functionality."""


def test_get_site_artifacts(site_crate):
    """Test getting site artifacts."""
    artifacts = site_crate.get_site_artifacts("site001")

    assert "site_id" in artifacts
    assert artifacts["site_id"] == "site001"
    assert "parameters" in artifacts
    assert "datasets" in artifacts
    assert "files" in artifacts
    assert "step_runs" in artifacts
    assert "key_lineages" in artifacts


def test_site_artifacts_includes_parameters(site_crate):
    """Test that site artifacts include matching parameters."""
    artifacts = site_crate.get_site_artifacts("site001")

    assert len(artifacts["parameters"]) > 0
    # Should have site_id parameter
    site_params = [p for p in artifacts["parameters"] if p.get("name") == "site_id"]
    assert len(site_params) > 0
    assert site_params[0].get("value") == "site001"


def test_site_artifacts_includes_files(site_crate):
    """Test that site artifacts include matching files."""
    artifacts = site_crate.get_site_artifacts("site001")

    # Should find files mentioning site001
    assert len(artifacts["files"]) > 0
    file_names = [f.get("name", "") for f in artifacts["files"]]
    assert any("site001" in name for name in file_names)


def test_site_artifacts_includes_datasets(site_crate):
    """Test that site artifacts include matching datasets."""
    artifacts = site_crate.get_site_artifacts("site001")

    # Should find datasets mentioning site001
    dataset_names = [d.get("name", "") for d in artifacts["datasets"]]
    assert any("site001" in str(name) for name in dataset_names)


def test_site_artifacts_includes_step_runs(site_crate):
    """Test that site artifacts include step runs."""
    artifacts = site_crate.get_site_artifacts("site001")

    assert len(artifacts["step_runs"]) > 0
    # Each step run should have site_ids
    for run in artifacts["step_runs"]:
        assert "action" in run
        assert "tool" in run
        assert "site_ids" in run
        assert "site001" in run["site_ids"]


def test_site_artifacts_key_lineages(site_crate):
    """Test that site artifacts include key lineages."""
    artifacts = site_crate.get_site_artifacts("site001")

    assert isinstance(artifacts["key_lineages"], dict)


def test_site_artifacts_nonexistent_site(site_crate):
    """Test getting artifacts for non-existent site."""
    artifacts = site_crate.get_site_artifacts("nonexistent_site")

    assert artifacts["site_id"] == "nonexistent_site"
    # Should still return structure but with empty collections
    assert len(artifacts["parameters"]) == 0
    assert len(artifacts["step_runs"]) == 0


def test_site_artifacts_from_sample_crate(sample_crate):
    """Test getting site artifacts from sample crate."""
    artifacts = sample_crate.get_site_artifacts("site001")

    assert artifacts["site_id"] == "site001"
    # Should find the site_id parameter from fixture
    assert len(artifacts["parameters"]) > 0


def test_site_artifacts_step_run_summary(site_crate):
    """Test that step runs include proper summaries."""
    artifacts = site_crate.get_site_artifacts("site001")

    if artifacts["step_runs"]:
        run = artifacts["step_runs"][0]
        assert "action" in run
        assert "tool" in run
        assert "site_ids" in run
        # Action should have basic fields
        action = run["action"]
        assert "id" in action or "name" in action


def test_site_artifacts_files_by_name_pattern(site_crate):
    """Test that files are found by name pattern matching."""
    artifacts = site_crate.get_site_artifacts("site001")

    # Files should include any file whose alternateName contains site001
    file_entities = site_crate.get_file_entities("site001_output.csv")
    if file_entities:
        artifacts = site_crate.get_site_artifacts("site001")
        file_names = [f.get("name", "") for f in artifacts["files"]]
        assert any("site001" in name for name in file_names)
