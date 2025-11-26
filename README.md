# provenance-context

Python library for querying RO-Crate provenance metadata from CWL workflow runs. Provides lineage queries, site artifacts, and TOON encoding for LLM prompts.

## Installation

```bash
pip install provenance-context
```

For optional dependencies:

```bash
# Pandas support
pip install provenance-context[pandas]

# TOON encoding support (not available on PyPI, install from GitHub)
pip install git+https://github.com/toon-format/toon-python.git

# Or install both
pip install provenance-context[pandas]
pip install git+https://github.com/toon-format/toon-python.git
```

## Usage

```python
from provenance_context import ProvenanceCrate

# Load a RO-Crate
crate = ProvenanceCrate.from_dir("path/to/crate")
# or
crate = ProvenanceCrate.from_file("path/to/ro-crate-metadata.json")

# Query lineage
lineage = crate.get_file_lineage("output.csv")
site = crate.get_site_artifacts("site_id")
ancestry = crate.get_file_ancestry("output.csv")
descendants = crate.get_file_descendants("input.geojson")

# Encode as TOON for LLM prompts (requires toon-format)
toon_lineage = crate.to_toon_file_lineage("output.csv")
toon_site = crate.to_toon_site_summary("site_id")
```

## Features

- **Lineage Queries**: Query direct lineage, ancestry (upstream), and descendants (downstream) of files
- **Site Artifacts**: Get a site-centric view of provenance data
- **TOON Encoding**: Encode provenance data into TOON format for efficient LLM prompts
- **File Resolution**: Resolve RO-Crate File entities to local filesystem paths
- **Media Type Detection**: Automatically detect file types from metadata or extensions

## Documentation

See `provenance_toon_cheatsheet.md` for detailed usage examples and patterns.

## License

MIT

