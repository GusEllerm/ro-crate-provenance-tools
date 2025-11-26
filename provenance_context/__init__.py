from __future__ import annotations

from collections import defaultdict, deque

# PIL.Image was imported but never used - removed
from pathlib import Path
from typing import Any

try:
    # Official toon-python package
    from toon_format import encode as toon_encode
except ImportError:
    toon_encode = None

import json


class ProvenanceCrate:
    """
    Helper for querying a Workflow Run / Provenance Run RO-Crate.

    This class:
    - Loads a crate's `ro-crate-metadata.json`
    - Builds indexes over entities and CreateActions
    - Exposes high-level lineage queries such as:
      * get_file_lineage
      * get_file_ancestry
      * get_file_descendants
      * get_site_artifacts
    - Can resolve File entities to local paths (for CSVs, images, etc.)
    - Can emit TOON-encoded summaries for LLM prompts.

    Typical usage:

        crate = ProvenanceCrate.from_dir("med_prov.crate")
        # or: crate = ProvenanceCrate.from_file("med_prov.crate/ro-crate-metadata.json")

        lineage = crate.get_file_lineage("transect_time_series_tidally_corrected.csv")
        site = crate.get_site_artifacts("nzd0003")
        ancestry = crate.get_file_ancestry("transect_time_series_tidally_corrected.csv")
        descendants = crate.get_file_descendants("transects_extended.geojson")

        path = crate.get_local_path(lineage[0]["file"]["id"])
    """

    # ------------------------------------------------------------------
    # Construction / loading
    # ------------------------------------------------------------------

    def __init__(self, graph: list[dict[str, Any]], root_dir: str | None = None):
        """
        Initialise a ProvenanceCrate from an in-memory `@graph` list.

        Parameters
        ----------
        graph:
            The list of JSON-LD entities from `ro-crate-metadata.json`["@graph"].
        root_dir:
            Optional path to the crate directory on disk. If provided,
            File entities whose @id/contentUrl are relative paths will be
            resolved against this directory.
        """
        self.graph = graph
        self.root_dir: Path | None = Path(root_dir) if root_dir else None
        self.by_id: dict[str, dict[str, Any]] = {}
        self.actions: list[dict[str, Any]] = []
        self.actions_by_result: dict[str, list[str]] = {}
        self.actions_by_input: dict[str, list[str]] = {}
        self._build_indexes()

    @classmethod
    def from_file(cls, metadata_path: str) -> ProvenanceCrate:
        """
        Load a RO-Crate from a `ro-crate-metadata.json` file.

        Parameters
        ----------
        metadata_path:
            Path to the crate's `ro-crate-metadata.json`.

        Returns
        -------
        ProvenanceCrate
            An instance with indexes ready for lineage queries, with
            root_dir set to the parent directory of the metadata file.
        """
        metadata_path = Path(metadata_path)
        with metadata_path.open("r", encoding="utf-8") as f:
            meta = json.load(f)
        graph = meta["@graph"]
        root_dir = metadata_path.parent
        return cls(graph, root_dir=str(root_dir))

    @classmethod
    def from_dir(cls, crate_dir: str) -> ProvenanceCrate:
        """
        Load a crate from its directory, assuming `ro-crate-metadata.json`
        is at the root.
        """
        crate_dir = Path(crate_dir)
        metadata_path = crate_dir / "ro-crate-metadata.json"
        with metadata_path.open("r", encoding="utf-8") as f:
            meta = json.load(f)
        graph = meta["@graph"]
        return cls(graph, root_dir=str(crate_dir))

    # ------------------------------------------------------------------
    # Internal helpers / indexes
    # ------------------------------------------------------------------

    def _build_indexes(self) -> None:
        """
        Build lookup structures over the crate:

        - by_id: @id -> entity
        - actions: list of CreateAction entities
        - actions_by_result: entity_id -> [CreateAction.id] that generate it
        - actions_by_input:  entity_id -> [CreateAction.id] that use it
        """
        self.by_id = {e["@id"]: e for e in self.graph}
        self.actions = [e for e in self.graph if self._has_type(e, "CreateAction")]

        actions_by_result: dict[str, list[str]] = defaultdict(list)
        actions_by_input: dict[str, list[str]] = defaultdict(list)

        for act in self.actions:
            act_id = act["@id"]
            for key, index in (("result", actions_by_result), ("object", actions_by_input)):
                for obj in act.get(key, []):
                    oid = obj.get("@id") if isinstance(obj, dict) else obj
                    if oid:
                        index[oid].append(act_id)

        self.actions_by_result = dict(actions_by_result)
        self.actions_by_input = dict(actions_by_input)

    @staticmethod
    def _has_type(ent: dict[str, Any], tname: str) -> bool:
        """
        Return True if the entity has type `tname` (handles string or list).

        Parameters
        ----------
        ent:
            Entity from the crate's @graph.
        tname:
            Type name to test (e.g. "File", "Dataset", "CreateAction").
        """
        t = ent.get("@type")
        if isinstance(t, list):
            return tname in t
        return t == tname

    # ------------------------------------------------------------------
    # Summariser helpers (used in query outputs)
    # ------------------------------------------------------------------

    @staticmethod
    def _summarise_file(ent: dict[str, Any]) -> dict[str, Any]:
        """Return a compact summary for a File entity."""
        return {
            "id": ent["@id"],
            "name": ent.get("alternateName"),
            "sha1": ent.get("sha1"),
            "encodingFormat": ent.get("encodingFormat") or ent.get("fileFormat"),
            "exampleOfWork": ent.get("exampleOfWork"),
        }

    @staticmethod
    def _summarise_dataset(ent: dict[str, Any]) -> dict[str, Any]:
        """Return a compact summary for a Dataset entity."""
        return {
            "id": ent["@id"],
            "name": ent.get("alternateName"),
        }

    @staticmethod
    def _summarise_param(ent: dict[str, Any]) -> dict[str, Any]:
        """Return a compact summary for a PropertyValue parameter."""
        return {
            "id": ent["@id"],
            "name": ent.get("name"),
            "value": ent.get("value"),
            "exampleOfWork": ent.get("exampleOfWork"),
        }

    @staticmethod
    def _summarise_action(ent: dict[str, Any]) -> dict[str, Any]:
        """Return a compact summary for a CreateAction."""
        return {
            "id": ent["@id"],
            "name": ent.get("name"),
            "startTime": ent.get("startTime"),
            "endTime": ent.get("endTime"),
        }

    @staticmethod
    def _summarise_tool(ent: dict[str, Any] | None) -> dict[str, Any] | None:
        """Return a compact summary for a SoftwareApplication (or None)."""
        if not ent:
            return None
        return {
            "id": ent["@id"],
            "name": ent.get("name"),
            "type": ent.get("@type"),
            "inputs": ent.get("input", []),
            "outputs": ent.get("output", []),
        }

    # ------------------------------------------------------------------
    # Entity resolution + file system helpers
    # ------------------------------------------------------------------

    def _find_files_by_altname(self, pattern: str) -> list[dict[str, Any]]:
        """
        Find File entities whose `alternateName` contains a substring.

        Parameters
        ----------
        pattern:
            Substring to match within `alternateName`.

        Returns
        -------
        list of dict
            Matching File entities from the crate.
        """
        out: list[dict[str, Any]] = []
        for e in self.graph:
            if self._has_type(e, "File"):
                alt = e.get("alternateName", "")
                if isinstance(alt, str) and pattern in alt:
                    out.append(e)
        return out

    def get_image_files(self) -> list[dict[str, Any]]:
        """
        Return a list of image files in the crate, based on media type
        guessed from encodingFormat or alternateName extension.

        Each item is a FileSummary, e.g.:
          {
            "id": "...",
            "name": "plots/nzd0003_profile.jpg",
            "sha1": "...",
            "encodingFormat": "image/jpeg" or None,
            "exampleOfWork": {...}
          }
        """
        images: list[dict[str, Any]] = []
        for ent in self.graph:
            if not self._has_type(ent, "File"):
                continue
            summary = self._summarise_file(ent)
            if self.is_image(summary):
                images.append(summary)
        return images

    def get_file_entities(self, file_selector: str) -> list[dict[str, Any]]:
        """
        Resolve a file selector to one or more File entities.

        Resolution order:
        1. Exact match on `@id` (if the entity is a File)
        2. Exact match on `alternateName`
        3. Substring match on `alternateName`

        Parameters
        ----------
        file_selector:
            Either:
            - an exact `@id` of a File, or
            - a string to match against File.alternateName.

        Returns
        -------
        list of dict
            Matching File entities; may be empty.
        """
        # Case 1: exact @id
        ent = self.by_id.get(file_selector)
        if ent is not None and self._has_type(ent, "File"):
            return [ent]

        # Case 2: exact alternateName
        vals = list(self.by_id.values())
        exact = [
            e for e in vals if self._has_type(e, "File") and e.get("alternateName") == file_selector
        ]
        if exact:
            return exact

        # Case 3: substring match
        return self._find_files_by_altname(file_selector)

    def get_local_path(self, file: str | dict[str, Any]) -> Path | None:
        """
        Resolve a File entity (or its @id) to a local filesystem path.

        Returns None if:
        - root_dir is not set
        - the file does not have a local path representation
        - the @id/contentUrl looks like a remote IRI or fragment
        - the path does not exist
        """
        if self.root_dir is None:
            return None

        if isinstance(file, str):
            ent = self.by_id.get(file)
        else:
            ent = file

        if not ent or not self._has_type(ent, "File"):
            return None

        # Prefer contentUrl if present, otherwise use @id
        cid = ent.get("contentUrl") or ent.get("@id")
        if isinstance(cid, dict):
            cid = cid.get("@id")

        if not cid:
            return None

        # Skip obvious IRIs and fragments
        if cid.startswith("#") or "://" in cid:
            return None

        path = self.root_dir / cid
        return path if path.exists() else None

    # ---- media type helpers -------------------------------------------------

    @staticmethod
    def guess_media_type(file_summary: dict[str, Any]) -> str | None:
        """
        Guess a media type for the file using encodingFormat if present,
        otherwise by inspecting the name extension.
        """
        fmt = file_summary.get("encodingFormat")
        if fmt:
            return fmt

        name = (file_summary.get("name") or "").lower()

        if name.endswith(".csv"):
            return "text/csv"
        if name.endswith(".json"):
            return "application/json"
        if name.endswith(".geojson"):
            return "application/geo+json"
        if name.endswith(".png"):
            return "image/png"
        if name.endswith(".jpg") or name.endswith(".jpeg"):
            return "image/jpeg"
        if name.endswith(".tif") or name.endswith(".tiff"):
            return "image/tiff"
        if name.endswith(".xlsx"):
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

        return None

    @staticmethod
    def is_csv(file_summary: dict[str, Any]) -> bool:
        mt = (ProvenanceCrate.guess_media_type(file_summary) or "").lower()
        return mt in ("text/csv", "text/comma-separated-values")

    @staticmethod
    def is_image(file_summary: dict[str, Any]) -> bool:
        mt = (ProvenanceCrate.guess_media_type(file_summary) or "").lower()
        return mt.startswith("image/")

    @staticmethod
    def is_json(file_summary: dict[str, Any]) -> bool:
        mt = (ProvenanceCrate.guess_media_type(file_summary) or "").lower()
        return mt in ("application/json", "application/ld+json", "application/geo+json")

    # ---- convenience openers ------------------------------------------------

    def open_as_bytes(self, file_selector: str) -> bytes | None:
        """
        Return the raw bytes for the first File matching `file_selector`,
        or None if no file/path is found.
        """
        ents = self.get_file_entities(file_selector)
        if not ents:
            return None
        path = self.get_local_path(ents[0])
        if not path:
            return None
        return path.read_bytes()

    def open_as_text(self, file_selector: str, encoding: str = "utf-8") -> str | None:
        """
        Return the text content for the first File matching `file_selector`,
        decoded with the given encoding.
        """
        ents = self.get_file_entities(file_selector)
        if not ents:
            return None
        path = self.get_local_path(ents[0])
        if not path:
            return None
        return path.read_text(encoding=encoding)

    def open_as_dataframe(self, file_selector: str):
        """
        Convenience for CSV-like files, assuming pandas is installed.

        Returns a pandas.DataFrame, or None if the file/path is not found.
        Raises ValueError if the file does not look like a CSV.
        """
        import pandas as pd

        ents = self.get_file_entities(file_selector)
        if not ents:
            return None
        ent = ents[0]
        path = self.get_local_path(ent)
        if not path:
            return None

        summary = self._summarise_file(ent)
        mt = self.guess_media_type(summary)
        if mt not in ("text/csv", "text/comma-separated-values"):
            raise ValueError(f"{summary.get('name')} is not a CSV (mediaType={mt})")

        return pd.read_csv(path)

    # ------------------------------------------------------------------
    # Public lineage/query methods
    # ------------------------------------------------------------------

    def get_file_lineage(self, file_selector: str) -> list[dict[str, Any]]:
        """
        Return direct lineage for file(s) matching `file_selector`.

        For each matching File, this returns:
        - the file summary
        - the CreateAction that produced it (if any)
        - the SoftwareApplication used as instrument
        - the inputs (files, datasets, parameters, other entities)
        - any `site_id` parameter value(s) associated with the step run
        """
        results: list[dict[str, Any]] = []
        files = self.get_file_entities(file_selector)

        for f in files:
            fid = f["@id"]
            producers = self.actions_by_result.get(fid, [])

            if not producers:
                results.append(
                    {
                        "file": self._summarise_file(f),
                        "produced_by": None,
                        "site_ids": [],
                        "note": "No CreateAction found that lists this file in its result.",
                    }
                )
                continue

            for act_id in producers:
                act = self.by_id[act_id]
                inst = act.get("instrument")
                inst_id = inst.get("@id") if isinstance(inst, dict) else inst
                tool = self.by_id.get(inst_id) if inst_id else None

                inputs = {"files": [], "datasets": [], "parameters": [], "other": []}

                for obj in act.get("object", []):
                    oid = obj.get("@id") if isinstance(obj, dict) else obj
                    ent = self.by_id.get(oid)
                    if not ent:
                        continue
                    if self._has_type(ent, "File"):
                        inputs["files"].append(self._summarise_file(ent))
                    elif self._has_type(ent, "Dataset"):
                        inputs["datasets"].append(self._summarise_dataset(ent))
                    elif self._has_type(ent, "PropertyValue"):
                        inputs["parameters"].append(self._summarise_param(ent))
                    else:
                        inputs["other"].append(
                            {
                                "id": ent["@id"],
                                "type": ent.get("@type"),
                            }
                        )

                site_ids = [p["value"] for p in inputs["parameters"] if p.get("name") == "site_id"]

                results.append(
                    {
                        "file": self._summarise_file(f),
                        "produced_by": {
                            "action": self._summarise_action(act),
                            "tool": self._summarise_tool(tool),
                            "inputs": inputs,
                        },
                        "site_ids": site_ids,
                    }
                )

        return results

    def get_file_ancestry(
        self,
        file_selector: str,
        max_depth: int | None = None,
    ) -> dict[str, Any]:
        """
        Build an upstream provenance subgraph for file(s) matching `file_selector`.

        This walks backwards through CreateActions:
        file/dataset -> (generated by) -> CreateAction -> (used) -> input file/dataset.
        """
        files = self.get_file_entities(file_selector)
        if not files:
            return {"root_files": [], "entities": {}, "actions": {}, "edges": []}

        root_ids = [f["@id"] for f in files]

        entity_nodes: dict[str, dict[str, Any]] = {}
        action_nodes: dict[str, dict[str, Any]] = {}
        edges: list[dict[str, Any]] = []

        q = deque()
        visited_entities = set()
        visited_actions = set()

        for fid in root_ids:
            q.append((fid, 0))

        while q:
            ent_id, depth = q.popleft()
            if ent_id in visited_entities:
                continue
            visited_entities.add(ent_id)

            ent = self.by_id.get(ent_id)
            if not ent:
                continue

            # Only keep File/Dataset in entity_nodes
            if self._has_type(ent, "File"):
                entity_nodes[ent_id] = self._summarise_file(ent)
            elif self._has_type(ent, "Dataset"):
                entity_nodes[ent_id] = self._summarise_dataset(ent)
            else:
                # Not a data artefact we care about for recursion
                continue

            # Find the actions that generated this entity
            for act_id in self.actions_by_result.get(ent_id, []):
                act = self.by_id.get(act_id)
                if not act:
                    continue

                # Always record generated edge
                edges.append(
                    {
                        "type": "generated",
                        "action": act_id,
                        "entity": ent_id,
                    }
                )

                if act_id in visited_actions:
                    continue
                visited_actions.add(act_id)

                inst = act.get("instrument")
                inst_id = inst.get("@id") if isinstance(inst, dict) else inst
                tool = self.by_id.get(inst_id) if inst_id else None

                inputs = {"files": [], "datasets": [], "parameters": [], "other": []}
                for obj in act.get("object", []):
                    oid = obj.get("@id") if isinstance(obj, dict) else obj
                    ent2 = self.by_id.get(oid)
                    if not ent2:
                        continue
                    if self._has_type(ent2, "File"):
                        inputs["files"].append(self._summarise_file(ent2))
                    elif self._has_type(ent2, "Dataset"):
                        inputs["datasets"].append(self._summarise_dataset(ent2))
                    elif self._has_type(ent2, "PropertyValue"):
                        inputs["parameters"].append(self._summarise_param(ent2))
                    else:
                        inputs["other"].append(
                            {
                                "id": ent2["@id"],
                                "type": ent2.get("@type"),
                            }
                        )

                action_nodes[act_id] = {
                    "action": self._summarise_action(act),
                    "tool": self._summarise_tool(tool),
                    "inputs": inputs,
                }

                # Recurse into file/dataset inputs
                for f_in in inputs["files"]:
                    in_id = f_in["id"]
                    edges.append({"type": "used", "action": act_id, "entity": in_id})
                    if max_depth is None or depth + 1 <= max_depth:
                        q.append((in_id, depth + 1))

                for d_in in inputs["datasets"]:
                    in_id = d_in["id"]
                    edges.append({"type": "used", "action": act_id, "entity": in_id})
                    if max_depth is None or depth + 1 <= max_depth:
                        q.append((in_id, depth + 1))

        return {
            "root_files": [self._summarise_file(f) for f in files],
            "entities": entity_nodes,
            "actions": action_nodes,
            "edges": edges,
        }

    def get_site_artifacts(self, site_id: str) -> dict[str, Any]:
        """
        Return a site-centric view of the crate for a given `site_id`.

        This collects:
        - PropertyValue parameters where name == "site_id" and value == site_id
        - Datasets and Files whose `alternateName` contains the site_id
        - CreateActions whose inputs include a matching site_id PropertyValue
        - Key lineage summaries for important per-site outputs.
        """
        vals = list(self.by_id.values())

        # 1. PropertyValue parameters for this site
        params = [
            self._summarise_param(e)
            for e in vals
            if self._has_type(e, "PropertyValue")
            and e.get("name") == "site_id"
            and e.get("value") == site_id
        ]

        # 2. Datasets mentioning this site_id
        site_datasets = [
            self._summarise_dataset(e)
            for e in vals
            if self._has_type(e, "Dataset") and site_id in str(e.get("alternateName", ""))
        ]

        # 3. Files mentioning this site_id
        site_files = [
            self._summarise_file(e)
            for e in vals
            if self._has_type(e, "File") and site_id in str(e.get("alternateName", ""))
        ]

        # 4. Step runs tagged with this site_id
        site_action_ids = set()
        for act in self.actions:
            for obj in act.get("object", []):
                oid = obj.get("@id") if isinstance(obj, dict) else obj
                ent = self.by_id.get(oid)
                if (
                    ent
                    and self._has_type(ent, "PropertyValue")
                    and ent.get("name") == "site_id"
                    and ent.get("value") == site_id
                ):
                    site_action_ids.add(act["@id"])
                    break

        def summarise_run(act: dict[str, Any]) -> dict[str, Any]:
            inst = act.get("instrument")
            inst_id = inst.get("@id") if isinstance(inst, dict) else inst
            tool = self.by_id.get(inst_id) if inst_id else None

            sids: list[str] = []
            for obj in act.get("object", []):
                oid = obj.get("@id") if isinstance(obj, dict) else obj
                ent = self.by_id.get(oid)
                if ent and self._has_type(ent, "PropertyValue") and ent.get("name") == "site_id":
                    sids.append(ent.get("value"))

            return {
                "action": self._summarise_action(act),
                "tool": self._summarise_tool(tool),
                "site_ids": sids,
            }

        step_runs = [summarise_run(self.by_id[aid]) for aid in sorted(site_action_ids)]

        # 5. Key lineages for "important" per-site outputs
        key_base_names = [
            "transect_time_series.csv",
            "transect_time_series_despiked.csv",
            "transect_time_series_smoothed.csv",
            "transect_time_series_tidally_corrected.csv",
            "tides.csv",
            f"{site_id}.xlsx",
            f"linear_{site_id}.json",
        ]

        key_lineages: dict[str, Any] = {}
        for base in key_base_names:
            summaries = self.get_file_lineage(base)
            site_summaries = [s for s in summaries if site_id in s.get("site_ids", [])]
            if site_summaries:
                key_lineages[base] = site_summaries[0]  # assume one per site

        return {
            "site_id": site_id,
            "parameters": params,
            "datasets": site_datasets,
            "files": site_files,
            "step_runs": step_runs,
            "key_lineages": key_lineages,
        }

    def get_file_descendants(
        self,
        file_selector: str,
        max_depth: int | None = None,
    ) -> dict[str, Any]:
        """
        Forward provenance: given a file (or dataset), find downstream
        files/datasets and the actions that use it, recursively.

        This walks forwards through CreateActions:
        file/dataset -> (used by) -> CreateAction -> (generated) -> output file/dataset.
        """
        roots = self.get_file_entities(file_selector)
        if not roots:
            return {
                "root_files": [],
                "entities": {},
                "actions": {},
                "edges": [],
                "descendant_files": [],
            }

        root_ids = [r["@id"] for r in roots]
        q = deque((rid, 0) for rid in root_ids)

        entity_nodes: dict[str, dict[str, Any]] = {}
        action_nodes: dict[str, dict[str, Any]] = {}
        edges: list[dict[str, Any]] = []

        visited_entities = set()
        visited_actions = set()

        while q:
            ent_id, depth = q.popleft()
            if ent_id in visited_entities:
                continue
            visited_entities.add(ent_id)

            ent = self.by_id.get(ent_id)
            if not ent:
                continue

            # Record File/Dataset entities (others we ignore for propagation)
            if self._has_type(ent, "File"):
                entity_nodes[ent_id] = self._summarise_file(ent)
            elif self._has_type(ent, "Dataset"):
                entity_nodes[ent_id] = self._summarise_dataset(ent)
            else:
                # Not a data artefact; don't propagate further
                continue

            # For each action that USES this entity as input
            for act_id in self.actions_by_input.get(ent_id, []):
                act = self.by_id.get(act_id)
                if not act:
                    continue

                # Edge: entity is used by this action
                edges.append(
                    {
                        "type": "used",
                        "action": act_id,
                        "entity": ent_id,
                    }
                )

                # If we've seen this action before, we don't need to reprocess its outputs
                if act_id in visited_actions:
                    continue
                visited_actions.add(act_id)

                inst = act.get("instrument")
                inst_id = inst.get("@id") if isinstance(inst, dict) else inst
                tool = self.by_id.get(inst_id) if inst_id else None

                # Partition inputs
                inputs = {"files": [], "datasets": [], "parameters": [], "other": []}
                for obj in act.get("object", []):
                    oid = obj.get("@id") if isinstance(obj, dict) else obj
                    ent2 = self.by_id.get(oid)
                    if not ent2:
                        continue
                    if self._has_type(ent2, "File"):
                        inputs["files"].append(self._summarise_file(ent2))
                    elif self._has_type(ent2, "Dataset"):
                        inputs["datasets"].append(self._summarise_dataset(ent2))
                    elif self._has_type(ent2, "PropertyValue"):
                        inputs["parameters"].append(self._summarise_param(ent2))
                    else:
                        inputs["other"].append(
                            {
                                "id": ent2["@id"],
                                "type": ent2.get("@type"),
                            }
                        )

                # Partition outputs
                outputs = {"files": [], "datasets": [], "other": []}
                for res in act.get("result", []):
                    oid = res.get("@id") if isinstance(res, dict) else res
                    ent2 = self.by_id.get(oid)
                    if not ent2:
                        continue

                    if self._has_type(ent2, "File"):
                        fs = self._summarise_file(ent2)
                        outputs["files"].append(fs)
                        edges.append(
                            {
                                "type": "generated",
                                "action": act_id,
                                "entity": ent2["@id"],
                            }
                        )
                        # Recurse forward
                        if max_depth is None or depth + 1 <= max_depth:
                            q.append((ent2["@id"], depth + 1))

                    elif self._has_type(ent2, "Dataset"):
                        ds = self._summarise_dataset(ent2)
                        outputs["datasets"].append(ds)
                        edges.append(
                            {
                                "type": "generated",
                                "action": act_id,
                                "entity": ent2["@id"],
                            }
                        )
                        if max_depth is None or depth + 1 <= max_depth:
                            q.append((ent2["@id"], depth + 1))

                    else:
                        outputs["other"].append(
                            {
                                "id": ent2["@id"],
                                "type": ent2.get("@type"),
                            }
                        )
                        # No recursion through non-data outputs

                action_nodes[act_id] = {
                    "action": self._summarise_action(act),
                    "tool": self._summarise_tool(tool),
                    "inputs": inputs,
                    "outputs": outputs,
                }

        # Collect descendant files (exclude roots)
        descendant_files: list[dict[str, Any]] = []
        root_id_set = set(root_ids)
        for eid, summary in entity_nodes.items():
            if eid not in root_id_set and summary.get("sha1") is not None:
                descendant_files.append(summary)

        return {
            "root_files": [self._summarise_file(r) for r in roots],
            "entities": entity_nodes,
            "actions": action_nodes,
            "edges": edges,
            "descendant_files": descendant_files,
        }

    # ------------------------------------------------------------------
    # TOON integration helpers
    # ------------------------------------------------------------------

    def _ensure_toon_available(self) -> None:
        """
        Internal helper to assert that `toon_format` is installed.

        Raises
        ------
        RuntimeError
            If the `toon_format` package is not available.
        """
        if toon_encode is None:
            raise RuntimeError(
                "toon_format is not installed. Install with:\n"
                "  pip install git+https://github.com/toon-format/toon-python.git"
            )

    def to_toon(self, value: Any, options: dict[str, Any] | None = None) -> str:
        """
        Encode an arbitrary JSON-serialisable value into TOON.

        This is a thin wrapper around `toon_format.encode`, mainly so that
        lineage/site/graph methods can re-use a consistent encoding setup.
        """
        self._ensure_toon_available()
        if options is None:
            # Reasonable defaults for LLM prompts:
            # - 2-space indent
            # - comma delimiter
            # - no length marker (keep it visually simple)
            options = {"indent": 2, "delimiter": ",", "lengthMarker": ""}
        return toon_encode(value, options)

    def to_toon_file_lineage(
        self,
        file_selector: str,
        *,
        single: bool = True,
        options: dict[str, Any] | None = None,
    ) -> str:
        """
        Encode the direct lineage of one or more files into TOON.

        Wraps `get_file_lineage` and returns a compact TOON string.
        """
        lineages = self.get_file_lineage(file_selector)

        if single and len(lineages) == 1:
            payload: Any = {
                "type": "FileLineage",
                "file_selector": file_selector,
                "lineage": lineages[0],
            }
        else:
            payload = {
                "type": "FileLineageList",
                "file_selector": file_selector,
                "lineages": lineages,
            }

        return self.to_toon(payload, options)

    def to_toon_site_summary(
        self,
        site_id: str,
        *,
        include_all_files: bool = False,
        options: dict[str, Any] | None = None,
    ) -> str:
        """
        Encode a site-centric slice of the provenance into TOON.

        Uses `get_site_artifacts` internally, but reshapes `key_lineages`
        into an array so TOON can tabularise repeated fields.
        """
        summary = self.get_site_artifacts(site_id)

        # Reshape key_lineages: dict[basename -> LineageSummary]
        kl = summary.get("key_lineages", {})
        key_lineages_list: list[dict[str, Any]] = []
        for basename, lineage in kl.items():
            key_lineages_list.append(
                {
                    "basename": basename,
                    "lineage": lineage,
                }
            )

        payload: dict[str, Any] = {
            "type": "SiteSummary",
            "site_id": site_id,
            "key_lineages": key_lineages_list,
        }

        if include_all_files:
            payload["parameters"] = summary.get("parameters", [])
            payload["datasets"] = summary.get("datasets", [])
            payload["files"] = summary.get("files", [])
            payload["step_runs"] = summary.get("step_runs", [])

        return self.to_toon(payload, options)

    def to_toon_file_ancestry(
        self,
        file_selector: str,
        *,
        max_depth: int | None = None,
        options: dict[str, Any] | None = None,
    ) -> str:
        """
        Encode the upstream provenance DAG of a file into TOON.

        Wraps `get_file_ancestry`, reshaping dicts into arrays so TOON
        can use tabular encoding.
        """
        graph = self.get_file_ancestry(file_selector, max_depth=max_depth)

        entities_map = graph.get("entities", {})
        actions_map = graph.get("actions", {})

        entities_list = list(entities_map.values())
        actions_list: list[dict[str, Any]] = []
        for aid, adata in actions_map.items():
            actions_list.append(
                {
                    "id": aid,
                    **adata,
                }
            )

        payload = {
            "type": "FileAncestry",
            "file_selector": file_selector,
            "root_files": graph.get("root_files", []),
            "entities": entities_list,
            "actions": actions_list,
            "edges": graph.get("edges", []),
        }

        return self.to_toon(payload, options)

    def to_toon_file_descendants(
        self,
        file_selector: str,
        *,
        max_depth: int | None = None,
        options: dict[str, Any] | None = None,
    ) -> str:
        """
        Encode the downstream provenance DAG of a file into TOON.

        Wraps `get_file_descendants`, reshaping dicts into arrays for
        better TOON tabular encoding.
        """
        graph = self.get_file_descendants(file_selector, max_depth=max_depth)

        entities_map = graph.get("entities", {})
        actions_map = graph.get("actions", {})

        entities_list = list(entities_map.values())
        actions_list: list[dict[str, Any]] = []
        for aid, adata in actions_map.items():
            actions_list.append(
                {
                    "id": aid,
                    **adata,
                }
            )

        payload = {
            "type": "FileDescendants",
            "file_selector": file_selector,
            "root_files": graph.get("root_files", []),
            "entities": entities_list,
            "actions": actions_list,
            "edges": graph.get("edges", []),
            "descendant_files": graph.get("descendant_files", []),
        }

        return self.to_toon(payload, options)


if __name__ == "__main__":
    import pprint

    # Load from the crate directory so we can resolve file paths
    crate = ProvenanceCrate.from_dir("med_prov.crate")

    # --- Example 1: CSV provenance + data -----------------------------------
    print("=== CSV example ===")
    csv_lineages = crate.get_file_lineage("transect_time_series_tidally_corrected.csv")
    if csv_lineages:
        lin = csv_lineages[0]
        pprint.pprint(lin)

        file_summary = lin["file"]
        csv_path = crate.get_local_path(file_summary["id"])
        media_type = ProvenanceCrate.guess_media_type(file_summary)

        print("CSV path     :", csv_path)
        print("CSV mediaType:", media_type)

        try:
            df = crate.open_as_dataframe("transect_time_series_tidally_corrected.csv")
            print("CSV head:")
            print(df.head())
        except Exception as e:
            print("Could not open CSV as DataFrame:", e)

    # --- Example 2: image / JPG example -------------------------------------
    print("\n=== Image example ===")
    image_files = crate.get_image_files()

    if not image_files:
        print("No image files detected in this crate.")
    else:
        img_summary = image_files[0]  # just take the first one
        pprint.pprint(img_summary)

        img_path = crate.get_local_path(img_summary["id"])
        img_media_type = ProvenanceCrate.guess_media_type(img_summary)

        print("Image path     :", img_path)
        print("Image mediaType:", img_media_type)

        # If you want to actually read the bytes (e.g. to embed or inspect):
        img_bytes = crate.open_as_bytes(img_summary["id"])
        print("Image size (bytes):", len(img_bytes) if img_bytes is not None else "N/A")
