{
    "$graph": [
        {
            "class": "CommandLineTool",
            "label": "Process single NZD site with CoastSat",
            "doc": "Runs the batch_process_NZ logic for a single site.\nThis tool is intended to be scattered over a list of NZD site IDs.\nIt:\n  - reads polygons, shorelines and transects GeoJSON files\n  - reads any existing transect_time_series.csv for that site\n  - downloads and processes new imagery with CoastSat\n  - writes ./<site-id>/transect_time_series.csv as output\n",
            "hints": [
                {
                    "secrets": [
                        "#batch_process_nz.cwl/gee_key_json"
                    ],
                    "class": "http://commonwl.org/cwltool#Secrets"
                }
            ],
            "requirements": [
                {
                    "listing": [
                        {
                            "entryname": "process_nzd_site.py",
                            "entry": "#!/usr/bin/env python3\n#!/usr/bin/env python3\nimport os\nimport sys\nimport argparse\nimport warnings\nimport tempfile\nimport time\nfrom datetime import timedelta\n\nimport numpy as np\nimport pandas as pd\nimport geopandas as gpd\nimport ee\nfrom shapely.ops import split\nfrom shapely import line_merge\n\nfrom coastsat import SDS_download, SDS_shoreline, SDS_tools, SDS_transects\n\nwarnings.filterwarnings(\"ignore\")\n\nCRS = 2193  # NZTM2000\n\ndef init_gee(gee_key_json: str, service_account: str) -> str:\n    \"\"\"Initialise Earth Engine using a service-account JSON string.\n\n    Returns the path to the temporary key file so the caller can\n    clean it up later if desired.\n    \"\"\"\n    fd, key_path = tempfile.mkstemp(prefix=\"gee-key-\", suffix=\".json\")\n    os.close(fd)\n    with open(key_path, \"w\") as f:\n        f.write(gee_key_json)\n    credentials = ee.ServiceAccountCredentials(service_account, key_path)\n    ee.Initialize(credentials)\n    return key_path\n\n\ndef process_site(\n    sitename: str,\n    poly: gpd.GeoDataFrame,\n    shorelines: gpd.GeoDataFrame,\n    transects_gdf: gpd.GeoDataFrame,\n    existing_df: pd.DataFrame,\n    min_date\n):\n    \"\"\"Run the CoastSat shoreline workflow for a single site.\n\n    Returns a concatenated DataFrame (existing + new results),\n    or None if no new results are available.\n    \"\"\"\n    print(f\"Now processing {sitename}\")\n\n    inputs = {\n        \"polygon\": list(poly.geometry[sitename].exterior.coords),\n        \"dates\": [min_date, \"2030-12-30\"],  # all available imagery\n        \"sat_list\": [\"L5\", \"L7\", \"L8\", \"L9\"],\n        \"sitename\": sitename,\n        # put outputs under ./<sitename> relative to CWL step workdir\n        \"filepath\": os.path.abspath(\".\"),\n        \"landsat_collection\": \"C02\",\n    }\n\n    metadata = SDS_download.retrieve_images(inputs)\n\n    # settings for shoreline extraction (same as your NZ script)\n    settings = {\n        \"cloud_thresh\": 0.1,\n        \"dist_clouds\": 300,\n        \"output_epsg\": CRS,\n        \"check_detection\": False,\n        \"adjust_detection\": False,\n        \"save_figure\": True,\n        \"min_beach_area\": 1000,\n        \"min_length_sl\": 500,\n        \"cloud_mask_issue\": False,\n        \"sand_color\": \"default\",\n        \"pan_off\": False,\n        \"s2cloudless_prob\": 40,\n        \"inputs\": inputs,\n    }\n\n    # Optional quicklooks:\n    # SDS_preprocess.save_jpg(metadata, settings, use_matplotlib=True)\n\n    # Transects for this site\n    transects_at_site = transects_gdf[transects_gdf.site_id == sitename]\n    transects = {\n        transect_id: np.array(transects_at_site.geometry[transect_id].coords)\n        for transect_id in transects_at_site.index\n    }\n\n    # Reference shoreline (NZD version flips it)\n    ref_sl = np.array(\n        line_merge(split(shorelines.geometry[sitename], transects_at_site.unary_union)).coords\n    )\n    settings[\"max_dist_ref\"] = 300\n    settings[\"reference_shoreline\"] = np.flip(ref_sl)\n\n    output = SDS_shoreline.extract_shorelines(metadata, settings)\n    print(f\"Have {len(output['shorelines'])} new shorelines for {sitename}\")\n    if not output[\"shorelines\"]:\n        return None\n\n    # Flip each shoreline as in NZ script\n    output[\"shorelines\"] = [np.flip(s) for s in output[\"shorelines\"]]\n\n    # QC filters\n    output = SDS_tools.remove_duplicates(output)\n    output = SDS_tools.remove_inaccurate_georef(output, 10)\n\n    settings_transects = {\n        \"along_dist\": 25,\n        \"min_points\": 3,\n        \"max_std\": 15,\n        \"max_range\": 30,\n        \"min_chainage\": -100,\n        \"multiple_inter\": \"auto\",\n        \"auto_prc\": 0.1,\n    }\n\n    cross_distance = SDS_transects.compute_intersection_QC(\n        output, transects, settings_transects\n    )\n\n    out_dict = {}\n    out_dict[\"dates\"] = output[\"dates\"]\n    out_dict[\"satname\"] = output[\"satname\"]\n    for key in transects.keys():\n        out_dict[key] = cross_distance[key]\n\n    new_results = pd.DataFrame(out_dict)\n    if new_results.empty:\n        return None\n\n    if existing_df is None or existing_df.empty:\n        df = new_results\n    else:\n        df = pd.concat([existing_df, new_results], ignore_index=True)\n\n    df.sort_values(\"dates\", inplace=True)\n    return df\n\n\ndef main(argv=None) -> int:\n    parser = argparse.ArgumentParser(\n        description=\"Process a single NZD site with CoastSat (CWL-friendly)\"\n    )\n    parser.add_argument(\"--site-id\", required=True, help=\"Site ID, e.g. nzd0001\")\n    parser.add_argument(\"--polygons-geojson\", required=True, help=\"Polygons GeoJSON path\")\n    parser.add_argument(\"--shoreline-geojson\", required=True, help=\"Shorelines GeoJSON path\")\n    parser.add_argument(\"--transects-geojson\", required=True, help=\"Transects GeoJSON path\")\n    parser.add_argument(\n        \"--existing-ts-root\",\n        required=True,\n        help=\"Directory containing existing per-site transect_time_series.csv (subdir per site)\",\n    )\n    parser.add_argument(\n        \"--gee-key-json\",\n        required=True,\n        help=\"GEE service-account JSON (string, marked as secret in CWL)\",\n    )\n    parser.add_argument(\n        \"--service-account-email\",\n        required=False,\n        # falls back to your original hard-coded service account if env var not set\n        default=os.environ.get(\n            \"GEE_SERVICE_ACCOUNT\",\n            \"service-account@iron-dynamics-294100.iam.gserviceaccount.com\",\n        ),\n    )\n\n    args = parser.parse_args(argv)\n\n    start = time.time()\n    key_path = init_gee(args.gee_key_json, args.service_account_email)\n    print(f\"{time.time() - start:.1f}s: Logged into EE as {args.service_account_email}\")\n\n    # Load data for this site only\n    poly = gpd.read_file(args.polygons_geojson)\n    poly = poly[poly.id == args.site_id]\n    if poly.empty:\n        print(f\"No polygon found for site {args.site_id}\", file=sys.stderr)\n        return 1\n    poly.set_index(\"id\", inplace=True)\n\n    shorelines = gpd.read_file(args.shoreline_geojson)\n    shorelines = shorelines[shorelines.id == args.site_id].to_crs(CRS)\n    if shorelines.empty:\n        print(f\"No shoreline found for site {args.site_id}\", file=sys.stderr)\n        return 1\n    shorelines.set_index(\"id\", inplace=True)\n\n    transects_gdf = (\n        gpd.read_file(args.transects_geojson)\n        .to_crs(CRS)\n        .drop_duplicates(subset=\"id\")\n    )\n    transects_gdf.set_index(\"id\", inplace=True)\n\n    # Existing time-series, if any\n    existing_root = args.existing_ts_root\n    existing_csv = os.path.join(existing_root, args.site_id, \"transect_time_series.csv\")\n    try:\n        existing_df = pd.read_csv(existing_csv)\n        existing_df.dates = pd.to_datetime(existing_df.dates)\n        min_date = str(existing_df.dates.max().date() + timedelta(days=1))\n    except FileNotFoundError:\n        existing_df = pd.DataFrame()\n        min_date = \"1984-01-01\"\n\n    df = process_site(args.site_id, poly, shorelines, transects_gdf, existing_df, min_date)\n\n    if df is None:\n        # Case 1: we have existing data but nothing new \u2013 reuse the existing time series\n        if existing_df is not None and not existing_df.empty:\n            print(\n                f\"No new shorelines for {args.site_id}; \"\n                f\"reusing existing transect_time_series.csv from input.\"\n            )\n            df_to_write = existing_df\n        else:\n            # Case 2: no existing data and no new data \u2013 write an empty placeholder\n            # so CWL can still glob a file and downstream tools can handle \"no data\".\n            print(\n                f\"No shorelines and no existing time series for {args.site_id}; \"\n                f\"writing an empty placeholder transect_time_series.csv\"\n            )\n            df_to_write = pd.DataFrame(columns=[\"dates\", \"satname\"])\n    else:\n        # Normal case: we have a merged (existing + new) DataFrame\n        print(f\"[batch_process_sar] New data found for site {args.site_id}, writing to file.\")\n        df_to_write = df\n\n    # Write output: ./<site-id>/transect_time_series.csv in the CWL workdir\n    site_dir = os.path.join(os.getcwd(), args.site_id)\n    os.makedirs(site_dir, exist_ok=True)\n    out_csv = os.path.join(site_dir, \"transect_time_series.csv\")\n    df_to_write.to_csv(out_csv, index=False, float_format=\"%.2f\")\n    print(f\"{args.site_id} is done. Time-series saved as: {out_csv}\")\n    return 0\n\nif __name__ == \"__main__\":\n    raise SystemExit(main())\n"
                        }
                    ],
                    "class": "InitialWorkDirRequirement"
                },
                {
                    "class": "InlineJavascriptRequirement"
                }
            ],
            "baseCommand": [
                "python3",
                "process_nzd_site.py"
            ],
            "inputs": [
                {
                    "type": "string",
                    "inputBinding": {
                        "prefix": "--gee-key-json"
                    },
                    "id": "#batch_process_nz.cwl/gee_key_json"
                },
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--polygons-geojson"
                    },
                    "id": "#batch_process_nz.cwl/polygons_geojson"
                },
                {
                    "type": [
                        "null",
                        "string"
                    ],
                    "doc": "Optional GEE service account email. If not set, defaults to the hard-coded service account in the script or the GEE_SERVICE_ACCOUNT env var.\n",
                    "inputBinding": {
                        "prefix": "--service-account-email"
                    },
                    "id": "#batch_process_nz.cwl/service_account_email"
                },
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--shoreline-geojson"
                    },
                    "id": "#batch_process_nz.cwl/shoreline_geojson"
                },
                {
                    "type": "string",
                    "doc": "Site ID, e.g. nzd0001",
                    "inputBinding": {
                        "prefix": "--site-id"
                    },
                    "id": "#batch_process_nz.cwl/site_id"
                },
                {
                    "type": "Directory",
                    "doc": "Directory containing existing per-site transect_time_series.csv",
                    "inputBinding": {
                        "prefix": "--existing-ts-root"
                    },
                    "id": "#batch_process_nz.cwl/transect_time_series_per_site"
                },
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--transects-geojson"
                    },
                    "id": "#batch_process_nz.cwl/transects_extended_geojson"
                }
            ],
            "stdout": "process_site.log",
            "id": "#batch_process_nz.cwl",
            "outputs": [
                {
                    "type": "Directory",
                    "outputBinding": {
                        "glob": "$(inputs.site_id)"
                    },
                    "id": "#batch_process_nz.cwl/site_dir"
                },
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "$(inputs.site_id + \"/transect_time_series.csv\")"
                    },
                    "id": "#batch_process_nz.cwl/transect_time_series"
                }
            ]
        },
        {
            "class": "CommandLineTool",
            "label": "Process single SAR site with CoastSat",
            "doc": "Runs the batch_process_sar logic for a single site.\nThis tool is intended to be scattered over a list of SAR site IDs.\nIt:\n  - reads polygons, shorelines and transects GeoJSON files\n  - reads any existing transect_time_series.csv for that site\n  - downloads and processes new imagery with CoastSat\n  - writes ./<site-id>/transect_time_series.csv as output\n",
            "hints": [
                {
                    "secrets": [
                        "#batch_process_sar.cwl/gee_key_json"
                    ],
                    "class": "http://commonwl.org/cwltool#Secrets"
                }
            ],
            "requirements": [
                {
                    "listing": [
                        {
                            "entryname": "process_sar_site.py",
                            "entry": "#!/usr/bin/env python3\nimport os\nimport sys\nimport argparse\nimport warnings\nimport tempfile\nimport time\nfrom datetime import timedelta\n\nimport numpy as np\nimport pandas as pd\nimport geopandas as gpd\nimport ee\nfrom shapely.ops import split\nfrom shapely import line_merge\n\nfrom coastsat import SDS_download, SDS_shoreline, SDS_tools, SDS_transects\n\nwarnings.filterwarnings(\"ignore\")\n\nCRS = 3003  # Sardinia CRS\n\ndef init_gee(gee_key_json: str, service_account: str) -> str:\n    \"\"\"\n    Initialise Earth Engine using a service-account JSON string.\n    Returns the path to the temporary key file.\n    \"\"\"\n    fd, key_path = tempfile.mkstemp(prefix=\"gee-key-\", suffix=\".json\")\n    os.close(fd)\n    with open(key_path, \"w\") as f:\n        f.write(gee_key_json)\n    credentials = ee.ServiceAccountCredentials(service_account, key_path)\n    ee.Initialize(credentials)\n    return key_path\n\n\ndef process_site(\n    sitename: str,\n    poly: gpd.GeoDataFrame,\n    shorelines: gpd.GeoDataFrame,\n    transects_gdf: gpd.GeoDataFrame,\n    existing_df: pd.DataFrame,\n    min_date: str,\n):\n    \"\"\"\n    Run the CoastSat shoreline workflow for a single SAR site.\n    Returns a concatenated DataFrame (existing + new), or None if no new results.\n    \"\"\"\n    print(f\"Now processing {sitename}\")\n\n    inputs = {\n        \"polygon\": list(poly.geometry[sitename].exterior.coords),\n        \"dates\": [min_date, \"2030-12-30\"],  # all available imagery\n        \"sat_list\": [\"L5\", \"L7\", \"L8\", \"L9\"],\n        \"sitename\": sitename,\n        # put outputs under ./<sitename> relative to CWL step workdir\n        \"filepath\": os.path.abspath(\".\"),\n        \"landsat_collection\": \"C02\",\n    }\n\n    metadata = SDS_download.retrieve_images(inputs)\n\n    # shoreline extraction settings (from original SAR script)\n    settings = {\n        \"cloud_thresh\": 0.1,\n        \"dist_clouds\": 300,\n        \"output_epsg\": CRS,\n        \"check_detection\": False,\n        \"adjust_detection\": False,\n        \"save_figure\": True,\n        \"min_beach_area\": 1000,\n        \"min_length_sl\": 500,\n        \"cloud_mask_issue\": False,\n        \"sand_color\": \"default\",\n        \"pan_off\": False,\n        \"s2cloudless_prob\": 40,\n        \"inputs\": inputs,\n    }\n\n    # Transects for this site\n    transects_at_site = transects_gdf[transects_gdf.site_id == sitename]\n    transects = {\n        transect_id: np.array(transects_at_site.geometry[transect_id].coords)\n        for transect_id in transects_at_site.index\n    }\n\n    # Reference shoreline (no flip in SAR)\n    ref_sl = np.array(\n        line_merge(\n            split(shorelines.geometry[sitename], transects_at_site.unary_union)\n        ).coords\n    )\n    settings[\"max_dist_ref\"] = 300\n    settings[\"reference_shoreline\"] = ref_sl\n\n    output = SDS_shoreline.extract_shorelines(metadata, settings)\n    print(f\"Have {len(output['shorelines'])} new shorelines for {sitename}\")\n    if not output[\"shorelines\"]:\n        return None\n\n    # NOTE: SAR script does NOT flip shorelines\n    # output['shorelines'] = [np.flip(s) for s in output['shorelines']]\n\n    # QC filters (15 m, as in original SAR script)\n    output = SDS_tools.remove_duplicates(output)\n    output = SDS_tools.remove_inaccurate_georef(output, 15)\n\n    settings_transects = {\n        \"along_dist\": 25,\n        \"min_points\": 3,\n        \"max_std\": 15,\n        \"max_range\": 30,\n        \"min_chainage\": -100,\n        \"multiple_inter\": \"auto\",\n        \"auto_prc\": 0.1,\n    }\n\n    cross_distance = SDS_transects.compute_intersection_QC(\n        output, transects, settings_transects\n    )\n\n    out_dict = {}\n    out_dict[\"dates\"] = output[\"dates\"]\n    out_dict[\"satname\"] = output[\"satname\"]\n    for key in transects.keys():\n        out_dict[key] = cross_distance[key]\n\n    new_results = pd.DataFrame(out_dict)\n    if new_results.empty:\n        return None\n\n    if existing_df is None or existing_df.empty:\n        df = new_results\n    else:\n        df = pd.concat([existing_df, new_results], ignore_index=True)\n\n    df.sort_values(\"dates\", inplace=True)\n    return df\n\n\ndef main(argv=None) -> int:\n    parser = argparse.ArgumentParser(\n        description=\"Process a single SAR site with CoastSat (CWL-friendly)\"\n    )\n    parser.add_argument(\"--site-id\", required=True, help=\"Site ID, e.g. sar0001\")\n    parser.add_argument(\"--polygons-geojson\", required=True, help=\"Polygons GeoJSON path\")\n    parser.add_argument(\"--shoreline-geojson\", required=True, help=\"Shorelines GeoJSON path\")\n    parser.add_argument(\"--transects-geojson\", required=True, help=\"Transects GeoJSON path\")\n    parser.add_argument(\n        \"--existing-ts-root\",\n        required=True,\n        help=\"Directory containing existing per-site transect_time_series.csv (subdir per site)\",\n    )\n    parser.add_argument(\n        \"--gee-key-json\",\n        required=True,\n        help=\"GEE service-account JSON (string, marked as secret in CWL)\",\n    )\n    parser.add_argument(\n        \"--service-account-email\",\n        required=False,\n        default=os.environ.get(\n            \"GEE_SERVICE_ACCOUNT\",\n            \"service-account@iron-dynamics-294100.iam.gserviceaccount.com\",\n        ),\n    )\n\n    args = parser.parse_args(argv)\n\n    start = time.time()\n    key_path = init_gee(args.gee_key_json, args.service_account_email)\n    print(f\"{time.time() - start:.1f}s: Logged into EE as {args.service_account_email}\")\n\n    # Load data for this site only\n    poly = gpd.read_file(args.polygons_geojson)\n    poly = poly[poly.id == args.site_id]\n    if poly.empty:\n        print(f\"No polygon found for site {args.site_id}\", file=sys.stderr)\n        return 1\n    poly.set_index(\"id\", inplace=True)\n\n    shorelines = gpd.read_file(args.shoreline_geojson)\n    shorelines = shorelines[shorelines.id == args.site_id].to_crs(CRS)\n    if shorelines.empty:\n        print(f\"No shoreline found for site {args.site_id}\", file=sys.stderr)\n        return 1\n    shorelines.set_index(\"id\", inplace=True)\n\n    transects_gdf = (\n        gpd.read_file(args.transects_geojson)\n        .to_crs(CRS)\n        .drop_duplicates(subset=\"id\")\n    )\n    transects_gdf.set_index(\"id\", inplace=True)\n\n    # Existing time-series, if any\n    existing_root = args.existing_ts_root\n    existing_csv = os.path.join(existing_root, args.site_id, \"transect_time_series.csv\")\n    try:\n        existing_df = pd.read_csv(existing_csv)\n        existing_df.dates = pd.to_datetime(existing_df.dates)\n        min_date = str(existing_df.dates.max().date() + timedelta(days=1))\n    except FileNotFoundError:\n        existing_df = pd.DataFrame()\n        min_date = \"1900-01-01\"  # SAR default from original script\n\n    df = process_site(args.site_id, poly, shorelines, transects_gdf, existing_df, min_date)\n    if df is None:\n        # Case 1: we have existing data but nothing new \u2013 reuse the existing time series\n        if existing_df is not None and not existing_df.empty:\n            print(\n                f\"No new shorelines for {args.site_id}; \"\n                f\"reusing existing transect_time_series.csv from input.\"\n            )\n            df_to_write = existing_df\n        else:\n            # Case 2: no existing data and no new data \u2013 write an empty placeholder\n            # so CWL can still glob a file and downstream tools can handle 'no data'.\n            print(\n                f\"No shorelines and no existing time series for {args.site_id}; \"\n                f\"writing an empty placeholder transect_time_series.csv\"\n            )\n            df_to_write = pd.DataFrame(columns=[\"dates\", \"satname\"])\n    else:\n        # Normal case: we have a merged (existing + new) DataFrame\n        print(f\"[batch_process_sar] New data found for site {args.site_id}, writing to file.\")\n        df_to_write = df\n\n    # Write output: ./<site-id>/transect_time_series.csv\n    site_dir = os.path.join(os.getcwd(), args.site_id)\n    os.makedirs(site_dir, exist_ok=True)\n    out_csv = os.path.join(site_dir, \"transect_time_series.csv\")\n    df_to_write.to_csv(out_csv, index=False, float_format=\"%.2f\")\n    print(f\"{args.site_id} is done. Time-series saved as: {out_csv}\")\n    return 0\n\n\n\nif __name__ == \"__main__\":\n    raise SystemExit(main())\n"
                        }
                    ],
                    "class": "InitialWorkDirRequirement"
                },
                {
                    "class": "InlineJavascriptRequirement"
                }
            ],
            "baseCommand": [
                "python3",
                "process_sar_site.py"
            ],
            "inputs": [
                {
                    "type": "string",
                    "inputBinding": {
                        "prefix": "--gee-key-json"
                    },
                    "id": "#batch_process_sar.cwl/gee_key_json"
                },
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--polygons-geojson"
                    },
                    "id": "#batch_process_sar.cwl/polygons_geojson"
                },
                {
                    "type": [
                        "null",
                        "string"
                    ],
                    "doc": "Optional GEE service account email. If not set, defaults to the hard-coded service account in the script or the GEE_SERVICE_ACCOUNT env var.\n",
                    "inputBinding": {
                        "prefix": "--service-account-email"
                    },
                    "id": "#batch_process_sar.cwl/service_account_email"
                },
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--shoreline-geojson"
                    },
                    "id": "#batch_process_sar.cwl/shoreline_geojson"
                },
                {
                    "type": "string",
                    "doc": "Site ID, e.g. sar0001",
                    "inputBinding": {
                        "prefix": "--site-id"
                    },
                    "id": "#batch_process_sar.cwl/site_id"
                },
                {
                    "type": "Directory",
                    "doc": "Directory containing existing per-site transect_time_series.csv",
                    "inputBinding": {
                        "prefix": "--existing-ts-root"
                    },
                    "id": "#batch_process_sar.cwl/transect_time_series_per_site"
                },
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--transects-geojson"
                    },
                    "id": "#batch_process_sar.cwl/transects_extended_geojson"
                }
            ],
            "stdout": "process_site.log",
            "outputs": [
                {
                    "type": "Directory",
                    "outputBinding": {
                        "glob": "$(inputs.site_id)"
                    },
                    "id": "#batch_process_sar.cwl/site_dir"
                },
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "$(inputs.site_id + \"/transect_time_series.csv\")"
                    },
                    "id": "#batch_process_sar.cwl/transect_time_series"
                }
            ],
            "id": "#batch_process_sar.cwl"
        },
        {
            "class": "CommandLineTool",
            "label": "Create trimmed per-site directory without imagery",
            "requirements": [
                {
                    "listing": [
                        {
                            "entryname": "trim_site_dir.py",
                            "entry": "#!/usr/bin/env python3\nimport argparse\nimport os\nimport shutil\nimport sys\n\ndef main(argv=None):\n    p = argparse.ArgumentParser(\n        description=\"Copy core outputs for a site into a clean directory\"\n    )\n    p.add_argument(\"--site-id\", required=True)\n    p.add_argument(\"--src-dir\", required=True)\n    args = p.parse_args(argv)\n\n    site_id = args.site_id\n    src = os.path.abspath(args.src_dir)\n\n    # Destination: a new directory named <site_id> in the CWL working dir\n    dst = os.path.join(os.getcwd(), site_id)\n    os.makedirs(dst, exist_ok=True)\n\n    # Files we definitely want to keep if present\n    keep_names = {\n        \"transect_time_series.csv\",\n        \"transect_time_series_tidally_corrected.csv\",\n        \"transect_time_series_despiked.csv\",\n        \"transect_time_series_smoothed.csv\",\n        \"tides.csv\",\n        f\"{site_id}.xlsx\",\n    }\n\n    # File extensions we treat as \"imagery\" to drop\n    image_exts = {\".tif\", \".tiff\", \".png\", \".jpg\", \".jpeg\", \".gif\"}\n\n    for name in os.listdir(src):\n        src_path = os.path.join(src, name)\n        if os.path.isdir(src_path):\n            # Skip all subdirectories (they usually hold imagery)\n            continue\n\n        ext = os.path.splitext(name)[1].lower()\n\n        # Explicit keep by name\n        if name in keep_names:\n            shutil.copy2(src_path, os.path.join(dst, name))\n            continue\n\n        # Skip obvious imagery\n        if ext in image_exts:\n            continue\n\n        # For everything else (non-imagery), keep by default\n        shutil.copy2(src_path, os.path.join(dst, name))\n\n    print(f\"[{site_id}] Created trimmed directory at {dst}\", file=sys.stderr)\n    return 0\n\nif __name__ == \"__main__\":\n    raise SystemExit(main())\n"
                        }
                    ],
                    "class": "InitialWorkDirRequirement"
                }
            ],
            "baseCommand": [
                "python3",
                "trim_site_dir.py"
            ],
            "inputs": [
                {
                    "type": "string",
                    "inputBinding": {
                        "prefix": "--site-id"
                    },
                    "id": "#clean_sar_site_dir.cwl/site_id"
                },
                {
                    "type": "Directory",
                    "inputBinding": {
                        "prefix": "--src-dir"
                    },
                    "id": "#clean_sar_site_dir.cwl/src_dir"
                }
            ],
            "outputs": [
                {
                    "type": "Directory",
                    "outputBinding": {
                        "glob": "$(inputs.site_id)"
                    },
                    "id": "#clean_sar_site_dir.cwl/site_dir"
                }
            ],
            "id": "#clean_sar_site_dir.cwl"
        },
        {
            "class": "CommandLineTool",
            "label": "Fetch NIWA tides for a single NZ site",
            "doc": "Given a site_id, polygons.geojson, and a per-site directory containing\ntransect_time_series.csv, fetches (or tops up) tides from the NIWA API\nand writes tides.csv for that site.\n\nThis tool is intended to be scattered over NZD site IDs.\nIt:\n  - reads the polygon centroid for the site from polygons_geojson\n  - reads dates from <site_id>/transect_time_series.csv\n  - reuses any existing tides.csv from a persistent root, if provided\n  - downloads only missing tides via NIWA's tides API\n  - writes ./<site_id>/tides.csv and ./<site_id>/transect_time_series.csv\n    in the step working directory\n",
            "hints": [
                {
                    "secrets": [
                        "#fetch_tides_nz_site.cwl/niwa_tide_api_key"
                    ],
                    "class": "http://commonwl.org/cwltool#Secrets"
                }
            ],
            "requirements": [
                {
                    "listing": [
                        {
                            "entryname": "fetch_tides_nz_site.py",
                            "entry": "#!/usr/bin/env python3\nimport os\nimport sys\nimport argparse\nimport warnings\nimport time\n\nimport pandas as pd\nimport geopandas as gpd\nimport requests\nfrom tqdm.auto import tqdm\n\nwarnings.filterwarnings(\"ignore\")\n\n\ndef get_tide_for_dt(point, dt, api_key):\n    \"\"\"\n    Fetch tide for a single datetime using NIWA tides API.\n\n    point: shapely Point with .x (lon), .y (lat)\n    dt: pandas.Timestamp (naive), rounded to 10 min\n    api_key: NIWA API key string\n    \"\"\"\n    while True:\n        try:\n            r = requests.get(\n                \"https://api.niwa.co.nz/tides/data\",\n                params={\n                    \"lat\": point.y,\n                    \"long\": point.x,\n                    \"numberOfDays\": 2,\n                    \"startDate\": str(dt.date()),\n                    \"datum\": \"MSL\",\n                    \"interval\": 10,  # minutes\n                    \"apikey\": api_key,\n                },\n                timeout=(30, 30),\n            )\n        except Exception as e:\n            print(f\"Error contacting NIWA API: {e}\", file=sys.stderr)\n            time.sleep(5)\n            continue\n\n        if r.status_code == 200:\n            data = r.json()\n            df = pd.DataFrame(data[\"values\"])\n            df.index = pd.to_datetime(df[\"time\"])\n            try:\n                return df.loc[dt, \"value\"]\n            except KeyError:\n                # No exact match at dt; fall back to nearest time\n                nearest = df.index.get_indexer([dt], method=\"nearest\")[0]\n                return df.iloc[nearest][\"value\"]\n        elif r.status_code == 429:\n            sleep_seconds = 30\n            print(\n                f\"NIWA API rate limit hit (429). Sleeping {sleep_seconds}s...\",\n                file=sys.stderr,\n            )\n            time.sleep(sleep_seconds)\n        else:\n            print(\n                f\"NIWA API error {r.status_code}: {r.text}\",\n                file=sys.stderr,\n            )\n            time.sleep(10)\n\n\ndef main(argv=None) -> int:\n    parser = argparse.ArgumentParser(\n        description=\"Fetch NIWA tides for a single NZ site.\"\n    )\n    parser.add_argument(\n        \"--site-id\", required=True, help=\"Site ID, e.g. nzd0001\"\n    )\n    parser.add_argument(\n        \"--polygons-geojson\",\n        required=True,\n        help=\"Polygons GeoJSON file containing NZD polygons\",\n    )\n    parser.add_argument(\n        \"--site-dir\",\n        required=True,\n        help=\"Per-site directory containing transect_time_series.csv \"\n             \"for the current run\",\n    )\n    parser.add_argument(\n        \"--existing-root\",\n        required=False,\n        help=\"Optional root directory containing persistent per-site \"\n             \"tides.csv (e.g. small_data/)\",\n    )\n    parser.add_argument(\n        \"--niwa-tide-api-key\",\n        required=True,\n        help=\"NIWA tide API key (string, marked as secret in CWL)\",\n    )\n\n    args = parser.parse_args(argv)\n\n    sitename = args.site_id\n    site_dir_in = os.path.abspath(args.site_dir)\n    ts_path_in = os.path.join(site_dir_in, \"transect_time_series.csv\")\n\n    if not os.path.isfile(ts_path_in):\n        print(\n            f\"No transect_time_series.csv found for {sitename} \"\n            f\"in {site_dir_in}\",\n            file=sys.stderr,\n        )\n        return 1\n\n    # Load polygons and get centroid for this site\n    poly = gpd.read_file(args.polygons_geojson)\n    poly = poly[poly.id == sitename]\n    if poly.empty:\n        print(f\"No polygon found for site {sitename}\", file=sys.stderr)\n        return 1\n    poly.set_index(\"id\", inplace=True)\n    point = poly.geometry[sitename].centroid\n\n    # Load transect time series dates\n    ts_df = pd.read_csv(ts_path_in)\n    sat_times = pd.to_datetime(ts_df[\"dates\"]).dt.round(\"10min\")\n\n    # Determine where existing tides may live\n    existing_root = (\n        os.path.abspath(args.existing_root)\n        if args.existing_root\n        else None\n    )\n    tides_df = None\n\n    if existing_root:\n        persistent_tides = os.path.join(\n            existing_root, sitename, \"tides.csv\"\n        )\n        if os.path.isfile(persistent_tides):\n            tides_df = pd.read_csv(persistent_tides)\n            tides_df.set_index(\"dates\", inplace=True)\n            tides_df.index = pd.to_datetime(tides_df.index)\n            print(\n                f\"Found existing tides for {sitename} in {persistent_tides}: \"\n                f\"{len(tides_df)} records\",\n                file=sys.stderr,\n            )\n\n    if tides_df is None:\n        # Optional: also look in the current per-run site dir\n        local_tides = os.path.join(site_dir_in, \"tides.csv\")\n        if os.path.isfile(local_tides):\n            tides_df = pd.read_csv(local_tides)\n            tides_df.set_index(\"dates\", inplace=True)\n            tides_df.index = pd.to_datetime(tides_df.index)\n            print(\n                f\"Found existing tides for {sitename} in {local_tides}: \"\n                f\"{len(tides_df)} records\",\n                file=sys.stderr,\n            )\n        else:\n            tides_df = pd.DataFrame(columns=[\"tide\"])\n            tides_df.index.name = \"dates\"\n\n    # Dates we already have tides for\n    if tides_df.empty:\n        existing_dates = pd.DatetimeIndex([])\n    else:\n        existing_dates = tides_df.index\n\n    missing = sat_times[~sat_times.isin(existing_dates)].unique()\n\n    if len(missing) == 0:\n        print(\n            f\"All {len(sat_times)} dates already have tides for {sitename}\",\n            file=sys.stderr,\n        )\n    else:\n        print(\n            f\"Fetching tides for {len(missing)} missing dates at {sitename}\",\n            file=sys.stderr,\n        )\n        results = []\n        for dt in tqdm(missing):\n            tide = get_tide_for_dt(point, dt, args.niwa_tide_api_key)\n            results.append({\"dates\": dt, \"tide\": tide})\n        new_tides = pd.DataFrame(results)\n        new_tides[\"dates\"] = pd.to_datetime(new_tides[\"dates\"])\n        new_tides.set_index(\"dates\", inplace=True)\n\n        if tides_df.empty:\n            tides_df = new_tides\n        else:\n            tides_df = pd.concat([tides_df, new_tides])\n            tides_df = tides_df[~tides_df.index.duplicated(keep=\"first\")]\n\n    tides_df.sort_index(inplace=True)\n\n    # Write outputs into ./<site_id>/ in this step's working dir\n    site_dir_out = os.path.join(os.getcwd(), sitename)\n    os.makedirs(site_dir_out, exist_ok=True)\n\n    # Copy transect_time_series.csv through\n    ts_path_out = os.path.join(site_dir_out, \"transect_time_series.csv\")\n    ts_df.to_csv(ts_path_out, index=False)\n\n    # Write tides.csv\n    tides_path_out = os.path.join(site_dir_out, \"tides.csv\")\n    tides_df.to_csv(tides_path_out)\n\n    print(\n        f\"Written tides for {sitename} to {tides_path_out} \"\n        f\"({len(tides_df)} rows)\",\n        file=sys.stderr,\n    )\n    return 0\n\n\nif __name__ == \"__main__\":\n    raise SystemExit(main())\n"
                        }
                    ],
                    "class": "InitialWorkDirRequirement"
                }
            ],
            "baseCommand": [
                "python3",
                "fetch_tides_nz_site.py"
            ],
            "inputs": [
                {
                    "type": [
                        "null",
                        "Directory"
                    ],
                    "doc": "Root directory containing any previously saved per-site tides.csv",
                    "inputBinding": {
                        "prefix": "--existing-root",
                        "valueFrom": "$(self.path)"
                    },
                    "id": "#fetch_tides_nz_site.cwl/existing_root"
                },
                {
                    "type": "string",
                    "inputBinding": {
                        "prefix": "--niwa-tide-api-key"
                    },
                    "id": "#fetch_tides_nz_site.cwl/niwa_tide_api_key"
                },
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--polygons-geojson"
                    },
                    "id": "#fetch_tides_nz_site.cwl/polygons_geojson"
                },
                {
                    "type": "Directory",
                    "doc": "Per-site directory containing transect_time_series.csv for this run",
                    "inputBinding": {
                        "prefix": "--site-dir",
                        "valueFrom": "$(self.path)"
                    },
                    "id": "#fetch_tides_nz_site.cwl/site_dir_in"
                },
                {
                    "type": "string",
                    "doc": "Site ID, e.g. nzd0001",
                    "inputBinding": {
                        "prefix": "--site-id"
                    },
                    "id": "#fetch_tides_nz_site.cwl/site_id"
                }
            ],
            "stdout": "fetch_tides.log",
            "outputs": [
                {
                    "type": "Directory",
                    "outputBinding": {
                        "glob": "$(inputs.site_id)"
                    },
                    "id": "#fetch_tides_nz_site.cwl/site_dir"
                },
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "$(inputs.site_id + \"/tides.csv\")"
                    },
                    "id": "#fetch_tides_nz_site.cwl/tides_csv"
                }
            ],
            "id": "#fetch_tides_nz_site.cwl"
        },
        {
            "class": "ExpressionTool",
            "doc": "ExpressionTool to extract nzd and sar prefix lists from grouped IDs.\n\nThis tool extracts the \"nzd\" and \"sar\" prefix lists from the grouped_ids_array,\nmaking them ready for direct handoff to subsequent workflow steps.\n\nTo add more prefix lists in the future, simply add additional outputs following\nthe same pattern.\n",
            "label": "Get NZD and SAR Lists",
            "requirements": [
                {
                    "class": "InlineJavascriptRequirement"
                }
            ],
            "inputs": [
                {
                    "type": {
                        "type": "array",
                        "items": {
                            "type": "array",
                            "items": "string"
                        }
                    },
                    "doc": "Array of arrays of strings from read_grouped_ids_array tool output",
                    "id": "#get_nzd_sar_lists.cwl/grouped_ids_array"
                }
            ],
            "expression": "${ \n  function findPrefixList(prefix) {\n    for (var i = 0; i < inputs.grouped_ids_array.length; i++) {\n      if (inputs.grouped_ids_array[i].length > 0) {\n        var firstId = inputs.grouped_ids_array[i][0].toLowerCase();\n        var prefixMatch = firstId.match(/^([^0-9]+)/);\n        if (prefixMatch && prefixMatch[1] === prefix) {\n          return inputs.grouped_ids_array[i];\n        }\n      }\n    }\n    return [];\n  }\n  return {\n    nzd_list: findPrefixList(\"nzd\"),\n    sar_list: findPrefixList(\"sar\")\n  };\n}\n",
            "outputs": [
                {
                    "type": {
                        "type": "array",
                        "items": "string"
                    },
                    "doc": "List of NZD site IDs (string[]).\nCan be directly passed to subsequent workflow steps.\n",
                    "id": "#get_nzd_sar_lists.cwl/nzd_list"
                },
                {
                    "type": {
                        "type": "array",
                        "items": "string"
                    },
                    "doc": "List of SAR site IDs (string[]).\nCan be directly passed to subsequent workflow steps.\n",
                    "id": "#get_nzd_sar_lists.cwl/sar_list"
                }
            ],
            "id": "#get_nzd_sar_lists.cwl"
        },
        {
            "class": "CommandLineTool",
            "doc": "Tool that groups polygon IDs by prefix from a GeoJSON file.\n\nTakes a GeoJSON FeatureCollection file and extracts IDs from features -> properties -> id.\nGroups IDs by their prefix (e.g., \"aus\", \"nzd\", \"sar\") and outputs a JSON array\nof arrays where each inner array contains IDs with the same prefix.\n",
            "label": "Group IDs by Prefix",
            "requirements": [
                {
                    "class": "InitialWorkDirRequirement",
                    "listing": [
                        {
                            "entryname": "group_by_prefix.py",
                            "entry": "#!/usr/bin/env python3\nimport argparse\nimport json\nimport os\nimport re\nimport sys\nfrom collections import defaultdict\n\n\ndef extract_prefix(site_id: str) -> str:\n    \"\"\"\n    Extract the prefix (leading non-digit characters) from a site ID.\n    Examples:\n      \"aus0001\" -> \"aus\"\n      \"nzd10\"   -> \"nzd\"\n      \"sar\"     -> \"sar\"\n      \"123abc\"  -> \"\"\n    \"\"\"\n    match = re.match(r\"\\D*\", site_id)\n    return match.group(0) if match else site_id\n\n\ndef main() -> int:\n    parser = argparse.ArgumentParser(\n        description=\"Group polygon IDs by prefix from GeoJSON file\"\n    )\n    parser.add_argument(\n        \"--input\",\n        required=True,\n        help=\"Path to input GeoJSON file\",\n    )\n    parser.add_argument(\n        \"--output-dir\",\n        required=True,\n        help=\"Output directory for grouped IDs JSON file\",\n    )\n\n    args = parser.parse_args()\n\n    # Load the input GeoJSON file\n    try:\n        with open(args.input, \"r\") as f:\n            data = json.load(f)\n    except FileNotFoundError:\n        print(f\"Error: file not found: {args.input}\", file=sys.stderr)\n        return 1\n    except json.JSONDecodeError as e:\n        print(f\"Error: invalid JSON in input file: {e}\", file=sys.stderr)\n        return 1\n\n    # Verify it's a FeatureCollection\n    if data.get(\"type\") != \"FeatureCollection\":\n        print(\n            f\"Error: input must be a GeoJSON FeatureCollection, \"\n            f\"got type: {data.get('type')}\",\n            file=sys.stderr,\n        )\n        return 1\n\n    # Group IDs by prefix\n    grouped = defaultdict(list)\n    for feature in data.get(\"features\", []):\n        site_id = feature.get(\"properties\", {}).get(\"id\")\n        if not site_id:\n            continue\n        prefix = extract_prefix(site_id)\n        grouped[prefix].append(site_id)\n\n    sorted_prefixes = sorted(grouped.keys())\n    result = [grouped[p] for p in sorted_prefixes]\n\n    os.makedirs(args.output_dir, exist_ok=True)\n    output_path = os.path.join(args.output_dir, \"grouped_ids.json\")\n\n    with open(output_path, \"w\") as f:\n        json.dump(result, f, indent=2)\n\n    total_ids = sum(len(g) for g in result)\n    print(f\"Grouped {total_ids} IDs into {len(result)} prefix groups\")\n    for prefix in sorted_prefixes:\n        print(f\"  {prefix}: {len(grouped[prefix])} sites\")\n    print(f\"Output written to: {output_path}\")\n\n    return 0\n\nif __name__ == \"__main__\":\n    sys.exit(main())\n"
                        }
                    ]
                }
            ],
            "inputs": [
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--input"
                    },
                    "doc": "GeoJSON FeatureCollection file containing polygon features.\nEach feature should have a properties.id field with a site identifier.\n",
                    "id": "#group_by_prefix.cwl/polygons_geojson"
                }
            ],
            "outputs": [
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "grouped_ids.json"
                    },
                    "doc": "JSON file containing an array of arrays of strings.\nEach inner array contains site IDs grouped by their prefix.\nFormat: [[\"aus0001\", \"aus0002\", ...], [\"nzd0001\", \"nzd0002\", ...], ...]\n",
                    "id": "#group_by_prefix.cwl/grouped_ids"
                }
            ],
            "baseCommand": [
                "python3",
                "group_by_prefix.py"
            ],
            "arguments": [
                "--output-dir",
                "$(runtime.outdir)"
            ],
            "stdout": "group_by_prefix.log",
            "stderr": "group_by_prefix.err",
            "id": "#group_by_prefix.cwl"
        },
        {
            "class": "CommandLineTool",
            "doc": "Tool to read the grouped_ids JSON file and pass it through.\nThis is a workaround since ExpressionTools can't handle large files with loadContents.\n",
            "label": "Read Grouped IDs Array",
            "requirements": [
                {
                    "class": "InitialWorkDirRequirement",
                    "listing": [
                        {
                            "entryname": "read_grouped_ids_array.py",
                            "entry": "#!/usr/bin/env python3\n\"\"\"Read JSON file and output as JSON array (passthrough for CWL).\"\"\"\nimport argparse\nimport json\nimport os\nimport sys\n\ndef main() -> int:\n    parser = argparse.ArgumentParser(\n        description=\"Read JSON file and output as JSON array\"\n    )\n    parser.add_argument(\n        \"--input\",\n        required=True,\n        help=\"Path to input JSON file\",\n    )\n    parser.add_argument(\n        \"--output-dir\",\n        required=True,\n        help=\"Output directory for JSON file\",\n    )\n\n    args = parser.parse_args()\n\n    try:\n        # Read input JSON file\n        with open(args.input, \"r\") as f:\n            data = json.load(f)\n\n        # Ensure output directory exists\n        os.makedirs(args.output_dir, exist_ok=True)\n\n        # Construct output file path\n        output_path = os.path.join(args.output_dir, \"grouped_ids_array.json\")\n\n        # Write output JSON file\n        with open(output_path, \"w\") as f:\n            json.dump(data, f)\n\n        print(f\"Output written to: {output_path}\")\n        return 0\n\n    except FileNotFoundError:\n        print(f\"Error: file not found: {args.input}\", file=sys.stderr)\n        return 1\n    except json.JSONDecodeError as e:\n        print(f\"Error: invalid JSON in input file: {e}\", file=sys.stderr)\n        return 1\n    except Exception as e:\n        print(f\"Error: {e}\", file=sys.stderr)\n        return 1\n\nif __name__ == \"__main__\":\n    sys.exit(main())\n"
                        }
                    ]
                }
            ],
            "inputs": [
                {
                    "type": "File",
                    "doc": "The JSON file output from group_by_prefix tool",
                    "id": "#read_grouped_ids_array.cwl/grouped_ids_json"
                }
            ],
            "baseCommand": [
                "python3",
                "read_grouped_ids_array.py"
            ],
            "arguments": [
                "--input",
                "$(inputs.grouped_ids_json)",
                "--output-dir",
                "$(runtime.outdir)"
            ],
            "outputs": [
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "grouped_ids_array.json"
                    },
                    "doc": "JSON file containing the array (for use with ExpressionTool)",
                    "id": "#read_grouped_ids_array.cwl/grouped_ids_array_file"
                }
            ],
            "id": "#read_grouped_ids_array.cwl"
        },
        {
            "class": "ExpressionTool",
            "doc": "ExpressionTool to convert the JSON file to a string[][] array.\nThis reads from a file that was prepared by read_grouped_ids_array.cwl.\n",
            "label": "Convert Grouped IDs to Array",
            "requirements": [
                {
                    "class": "InlineJavascriptRequirement"
                }
            ],
            "inputs": [
                {
                    "type": "File",
                    "loadContents": true,
                    "doc": "JSON file from read_grouped_ids_array tool",
                    "id": "#read_grouped_ids_array_expr.cwl/grouped_ids_array_file"
                }
            ],
            "expression": "${ \n  var data = JSON.parse(inputs.grouped_ids_array_file.contents);\n  return {grouped_ids_array: data};\n}\n",
            "outputs": [
                {
                    "type": {
                        "type": "array",
                        "items": {
                            "type": "array",
                            "items": "string"
                        }
                    },
                    "doc": "Array of arrays of strings, directly usable in subsequent steps.",
                    "id": "#read_grouped_ids_array_expr.cwl/grouped_ids_array"
                }
            ],
            "id": "#read_grouped_ids_array_expr.cwl"
        },
        {
            "class": "CommandLineTool",
            "label": "Fit linear shoreline trend for a single site",
            "requirements": [
                {
                    "listing": [
                        {
                            "entryname": "linear_models_site.py",
                            "entry": "#!/usr/bin/env python3\nimport argparse\nimport shutil\nimport json\nimport os\n\nimport numpy as np\nimport pandas as pd\nfrom sklearn.linear_model import LinearRegression\nfrom sklearn.metrics import (\n    mean_squared_error,\n    r2_score,\n    mean_absolute_error,\n    root_mean_squared_error,\n)\n# As in the notebook: use SDS_transects.despike helper\nfrom coastsat import SDS_transects\n\n\ndef despike(chainage: pd.Series, threshold: float = 40) -> pd.Series:\n    \"\"\"\n    Match linear_models.ipynb: use SDS_transects.identify_outliers to\n    drop spikes, returning a Series with filtered values and dates.\n    \"\"\"\n    chainage = chainage.dropna()\n    if chainage.empty:\n        return chainage\n    chainage_vals, dates = SDS_transects.identify_outliers(\n        chainage.tolist(), chainage.index.tolist(), threshold\n    )\n    return pd.Series(chainage_vals, index=dates)\n\n\ndef main(argv=None) -> int:\n    p = argparse.ArgumentParser()\n    p.add_argument(\"--site-id\", required=True)\n    p.add_argument(\"--site-dir\", required=True)\n    args = p.parse_args(argv)\n\n    site_id = args.site_id\n    site_dir = os.path.abspath(args.site_dir)\n\n    # Prefer tidally-corrected, fall back to raw.\n    # In the original notebook, `my_files` points at\n    # transect_time_series_tidally_corrected.csv, but\n    # here we support both patterns.\n    tc_path = os.path.join(site_dir, \"transect_time_series_tidally_corrected.csv\")\n    raw_path = os.path.join(site_dir, \"transect_time_series.csv\")\n\n    if os.path.exists(tc_path):\n        f = tc_path\n    elif os.path.exists(raw_path):\n        f = raw_path\n    else:\n        # Nothing to do for this site\n        with open(f\"linear_{site_id}.json\", \"w\") as fp:\n            json.dump({\"site_id\": site_id, \"trends\": {}}, fp, indent=2)\n        return 0\n\n    df = pd.read_csv(f)\n    # Robust datetime parse, as in the notebook\n    try:\n        df[\"dates\"] = pd.to_datetime(df[\"dates\"])\n    except Exception:\n        # If that fails, just log the filename like the notebook did\n        print(f\"Could not parse dates for {f}\")\n\n    # --- SAR / BER smoothing branch (from notebook) ---\n    if site_id.startswith(\"sar\") or site_id.startswith(\"ber\"):\n        smoothed_filename = f.replace(\".csv\", \"_smoothed.csv\")\n        try:\n            # If a smoothed file already exists, re-use it\n            df_smooth = pd.read_csv(smoothed_filename)\n            df_smooth[\"dates\"] = pd.to_datetime(df_smooth[\"dates\"])\n            df = df_smooth\n        except FileNotFoundError:\n            # Recreate the despiked + 180d-rolling-smoothed series\n            df[\"dates\"] = pd.to_datetime(df[\"dates\"])\n            df.set_index(\"dates\", inplace=True)\n\n            # Preserve satname if present; despike numeric columns\n            satname = df.get(\"satname\", None)\n            df_no_sat = df.drop(columns=[\"satname\"], errors=\"ignore\")\n            df_des = df_no_sat.apply(despike, axis=0)\n            if satname is not None:\n                df_des[\"satname\"] = satname\n\n            # Save despiked version\n            df_des.reset_index(names=\"dates\").to_csv(\n                f.replace(\".csv\", \"_despiked.csv\"), index=False\n            )\n\n            # 180-day rolling mean on all transect columns (exclude satname)\n            for col in df_des.drop(columns=[\"satname\"], errors=\"ignore\").columns:\n                df_des[col] = df_des[col].rolling(\"180d\", min_periods=1).mean()\n\n            df_des.reset_index(names=\"dates\", inplace=True)\n            df_des.to_csv(smoothed_filename, index=False)\n            df = df_des\n    # --- end SAR / BER special handling ---\n\n    # Time axis in fractional years since the earliest date in this file,\n    # as in the notebook:\n    #   df.index = (df.dates - df.dates.min()).dt.days / 365.25\n    df.index = (df[\"dates\"] - df[\"dates\"].min()).dt.days / 365.25\n\n    # Drop non-transect columns exactly like the notebook\n    df.drop(\n        columns=[\"dates\", \"satname\", \"Unnamed: 0\"],\n        inplace=True,\n        errors=\"ignore\",\n    )\n\n    trends = []\n    for transect_id in df.columns:\n        sub_df = df[transect_id].dropna()\n        if not len(sub_df):\n            continue\n\n        x = sub_df.index.to_numpy().reshape(-1, 1)\n        y = sub_df.to_numpy()\n\n        linear_model = LinearRegression().fit(x, y)\n        pred = linear_model.predict(x)\n\n        trends.append(\n            {\n                \"transect_id\": transect_id,\n                \"trend\": float(linear_model.coef_[0]),\n                \"intercept\": float(linear_model.intercept_),\n                \"n_points\": int(len(df[transect_id])),\n                \"n_points_nonan\": int(len(sub_df)),\n                \"r2_score\": float(r2_score(y, pred)),\n                \"mae\": float(mean_absolute_error(y, pred)),\n                \"mse\": float(mean_squared_error(y, pred)),\n                \"rmse\": float(root_mean_squared_error(y, pred)),\n            }\n        )\n\n    result = {\n        \"site_id\": site_id,\n        \"trends\": {t[\"transect_id\"]: t for t in trends},\n    }\n\n    with open(f\"linear_{site_id}.json\", \"w\") as fp:\n        json.dump(result, fp, indent=2)\n\n    out_site_dir = os.path.join(os.getcwd(), site_id)\n    os.makedirs(out_site_dir, exist_ok=True)\n\n    # Always copy the base time-series file we actually used (f)\n    if os.path.exists(f):\n        shutil.copy2(\n            f,\n            os.path.join(out_site_dir, os.path.basename(f)),\n        )\n\n    # For SAR/BER, we may also have despiked/smoothed variants\n    for suffix in (\"_despiked.csv\", \"_smoothed.csv\"):\n        candidate = f.replace(\".csv\", suffix)\n        if os.path.exists(candidate):\n            shutil.copy2(\n                candidate,\n                os.path.join(out_site_dir, os.path.basename(candidate)),\n            )\n\n    return 0\n\n\nif __name__ == \"__main__\":\n    raise SystemExit(main())\n"
                        }
                    ],
                    "class": "InitialWorkDirRequirement"
                }
            ],
            "baseCommand": [
                "python3",
                "linear_models_site.py"
            ],
            "inputs": [
                {
                    "type": "Directory",
                    "inputBinding": {
                        "prefix": "--site-dir"
                    },
                    "id": "#linear_models_site.cwl/site_dir"
                },
                {
                    "type": "string",
                    "inputBinding": {
                        "prefix": "--site-id"
                    },
                    "id": "#linear_models_site.cwl/site_id"
                }
            ],
            "outputs": [
                {
                    "type": "Directory",
                    "outputBinding": {
                        "glob": "$(inputs.site_id)"
                    },
                    "id": "#linear_models_site.cwl/site_dir_out"
                },
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "$( \"linear_\" + inputs.site_id + \".json\" )"
                    },
                    "id": "#linear_models_site.cwl/site_models"
                }
            ],
            "id": "#linear_models_site.cwl"
        },
        {
            "class": "CommandLineTool",
            "label": "Make global transects.xlsx summary (NZD sites)",
            "requirements": [
                {
                    "listing": [
                        {
                            "entryname": "make_transects_summary.py",
                            "entry": "#!/usr/bin/env python3\nimport argparse\nimport geopandas as gpd\nimport pandas as pd\n\ndef main(argv=None):\n    p = argparse.ArgumentParser()\n    p.add_argument(\"--transects-geojson\", required=True)\n    args = p.parse_args(argv)\n\n    transects = gpd.read_file(args.transects_geojson).drop_duplicates(subset=\"id\")\n    transects.set_index(\"id\", inplace=True)\n    transects = transects[transects.site_id.str.startswith(\"nzd\")].copy()\n\n    transects[\"land_x\"] = transects.geometry.apply(lambda x: x.coords[0][0])\n    transects[\"land_y\"] = transects.geometry.apply(lambda x: x.coords[0][1])\n    transects[\"sea_x\"]  = transects.geometry.apply(lambda x: x.coords[-1][0])\n    transects[\"sea_y\"]  = transects.geometry.apply(lambda x: x.coords[-1][1])\n    transects[\"center_x\"] = (transects[\"land_x\"] + transects[\"sea_x\"]) / 2\n    transects[\"center_y\"] = (transects[\"land_y\"] + transects[\"sea_y\"]) / 2\n\n    transects.to_excel(\"transects.xlsx\")\n    print(\"Wrote transects.xlsx for NZD sites\")\n    return 0\n\nif __name__ == \"__main__\":\n    raise SystemExit(main())\n"
                        }
                    ],
                    "class": "InitialWorkDirRequirement"
                }
            ],
            "baseCommand": [
                "python3",
                "make_transects_summary.py"
            ],
            "inputs": [
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--transects-geojson"
                    },
                    "id": "#make_transects_summary.cwl/transects_extended_geojson"
                }
            ],
            "outputs": [
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "transects.xlsx"
                    },
                    "id": "#make_transects_summary.cwl/transects_xlsx"
                }
            ],
            "id": "#make_transects_summary.cwl"
        },
        {
            "class": "CommandLineTool",
            "label": "Make per-site Excel summary for one NZD site",
            "requirements": [
                {
                    "listing": [
                        {
                            "entryname": "make_xlsx_site.py",
                            "entry": "#!/usr/bin/env python3\nimport argparse\nimport os\nimport sys\n\nimport geopandas as gpd\nimport pandas as pd\nfrom shapely import line_interpolate_point\n\n\ndef main(argv=None):\n    p = argparse.ArgumentParser(\n        description=\"Create per-site Excel summary (NZD sites)\"\n    )\n    p.add_argument(\"--site-id\", required=True)\n    p.add_argument(\"--site-dir\", required=True)\n    p.add_argument(\"--transects-geojson\", required=True)\n    args = p.parse_args(argv)\n\n    site_id = args.site_id\n    site_dir = os.path.abspath(args.site_dir)\n\n    # Load transects and restrict to NZD, as in original make_xlsx.py\n    transects = (\n        gpd.read_file(args.transects_geojson)\n        .drop_duplicates(subset=\"id\")\n    )\n    if \"site_id\" not in transects.columns:\n        print(\"transects file has no 'site_id' column\", file=sys.stderr)\n        return 1\n\n    transects = transects[transects.site_id.str.startswith(\"nzd\")].copy()\n    if transects.empty:\n        print(\"No NZD transects found; nothing to do.\", file=sys.stderr)\n        return 0\n\n    transects.set_index(\"id\", inplace=True)\n\n    # Reproject for distance-based interpolation (same idea as original)\n    transects_2193 = transects.to_crs(2193)\n\n    # Paths inside this site's directory\n    tc_path   = os.path.join(site_dir, \"transect_time_series_tidally_corrected.csv\")\n    raw_path  = os.path.join(site_dir, \"transect_time_series.csv\")\n    tides_path = os.path.join(site_dir, \"tides.csv\")\n\n    if os.path.exists(tc_path):\n        ts_path = tc_path\n    elif os.path.exists(raw_path):\n        ts_path = raw_path\n    else:\n        print(f\"[{site_id}] No transect_time_series CSV found\", file=sys.stderr)\n        return 0\n\n    if not os.path.exists(tides_path):\n        print(f\"[{site_id}] No tides.csv found\", file=sys.stderr)\n        return 0\n\n    # Load time-series and tides\n    intersects = pd.read_csv(ts_path)\n    if \"dates\" not in intersects.columns:\n        print(f\"[{site_id}] intersects CSV has no 'dates' column\", file=sys.stderr)\n        return 1\n    intersects.set_index(\"dates\", inplace=True)\n\n    tides = pd.read_csv(tides_path)\n\n    # Transects for this site\n    transects_at_site = transects[transects.site_id == site_id]\n    if transects_at_site.empty:\n        print(f\"[{site_id}] No transects in transects_extended.geojson\", file=sys.stderr)\n\n    # Excel output inside the site directory\n    out_xlsx_site = os.path.join(site_dir, f\"{site_id}.xlsx\")\n\n    with pd.ExcelWriter(out_xlsx_site) as writer:\n        # Sheet 1: original numeric intersects\n        intersects.to_excel(writer, sheet_name=\"Intersects\")\n\n        # Sheet 2: tides\n        tides.to_excel(writer, sheet_name=\"Tides\", index=False)\n\n        # Sheet 3: transect rows for this site\n        transects_at_site.to_excel(writer, sheet_name=\"Transects\")\n\n        # Sheet 4: intersection points (lat,lon strings)\n        intersects_points = intersects.copy()\n        transect_ids = list(transects_at_site.index)\n\n        for transect_id in transect_ids:\n            if transect_id not in intersects_points.columns:\n                continue\n\n            distances = intersects_points[transect_id]\n            points = []\n            for d in distances:\n                if pd.isna(d):\n                    points.append(None)\n                else:\n                    try:\n                        geom = transects_2193.geometry[transect_id]\n                        pt = line_interpolate_point(geom, d)\n                    except Exception:\n                        pt = None\n                    points.append(pt)\n\n            # Convert to lat/lon WGS84\n            if points:\n                gs = gpd.GeoSeries(points, crs=transects_2193.crs)\n                gs_ll = gs.to_crs(4326)\n                intersects_points[transect_id] = [\n                    f\"{p.y},{p.x}\" if p is not None else None\n                    for p in gs_ll\n                ]\n\n        intersects_points.to_excel(writer, sheet_name=\"Intersect points\")\n\n    # Also drop a copy in the CWL working dir so glob can find it easily\n    cwd_xlsx = os.path.join(os.getcwd(), f\"{site_id}.xlsx\")\n    if os.path.abspath(cwd_xlsx) != os.path.abspath(out_xlsx_site):\n        import shutil\n        shutil.copy2(out_xlsx_site, cwd_xlsx)\n\n    print(f\"[{site_id}] Wrote Excel summary to {out_xlsx_site}\")\n    return 0\n\nif __name__ == \"__main__\":\n    raise SystemExit(main())\n"
                        }
                    ],
                    "class": "InitialWorkDirRequirement"
                }
            ],
            "baseCommand": [
                "python3",
                "make_xlsx_site.py"
            ],
            "inputs": [
                {
                    "type": "Directory",
                    "inputBinding": {
                        "prefix": "--site-dir"
                    },
                    "id": "#make_xlsx_site.cwl/site_dir"
                },
                {
                    "type": "string",
                    "inputBinding": {
                        "prefix": "--site-id"
                    },
                    "id": "#make_xlsx_site.cwl/site_id"
                },
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--transects-geojson"
                    },
                    "id": "#make_xlsx_site.cwl/transects_extended_geojson"
                }
            ],
            "outputs": [
                {
                    "type": "Directory",
                    "outputBinding": {
                        "glob": ".",
                        "outputEval": "$(inputs.site_dir)"
                    },
                    "id": "#make_xlsx_site.cwl/site_dir_out"
                },
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "$(inputs.site_id + \".xlsx\")"
                    },
                    "id": "#make_xlsx_site.cwl/site_xlsx"
                }
            ],
            "id": "#make_xlsx_site.cwl"
        },
        {
            "class": "CommandLineTool",
            "label": "Merge per-site linear trends into transects_extended.geojson",
            "doc": "Reads an existing transects_extended.geojson (already augmented with slopes)\nand a collection of per-site linear trend JSON files (one per site),\nthen joins the trend metrics onto the transects table by transect_id/id.\n\nEach site_models file is expected to have structure:\n  {\n    \"site_id\": \"nzd0001\" | \"sar0001\" | ...,\n    \"trends\": {\n      \"<transect_id>\": {\n        \"trend\": ...,\n        \"intercept\": ...,\n        \"n_points\": ...,\n        \"n_points_nonan\": ...,\n        \"r2_score\": ...,\n        \"mae\": ...,\n        \"mse\": ...,\n        \"rmse\": ...\n      },\n      ...\n    }\n  }\n\nThe tool:\n  - loads transects_extended.geojson into a GeoDataFrame with index 'id'\n  - flattens all site_models into a single DataFrame indexed by transect_id\n  - drops any trend columns that already exist on transects\n  - performs transects = transects.join(trends_filtered)\n  - writes transects_extended.geojson in the current working directory.\n",
            "requirements": [
                {
                    "listing": [
                        {
                            "entryname": "merge_linear_models.py",
                            "entry": "#!/usr/bin/env python3\nimport argparse\nimport json\nimport sys\n\nimport geopandas as gpd\nimport pandas as pd\n\n\ndef main(argv=None) -> int:\n    p = argparse.ArgumentParser(\n        description=\"Merge per-site linear models into transects_extended.geojson\"\n    )\n    p.add_argument(\n        \"--transects-geojson\",\n        required=True,\n        help=\"Input transects_extended.geojson (with slopes etc.)\",\n    )\n    p.add_argument(\n        \"--site-models\",\n        nargs=\"+\",\n        required=True,\n        help=\"Per-site linear model JSON files\",\n    )\n    args = p.parse_args(argv)\n\n    # --- Load transects and choose ID column ---\n    transects = gpd.read_file(args.transects_geojson)\n\n    if \"id\" in transects.columns:\n        id_col = \"id\"\n    elif \"transect_id\" in transects.columns:\n        id_col = \"transect_id\"\n    else:\n        print(\n            \"Error: transects_extended.geojson has neither 'id' nor 'transect_id' column\",\n            file=sys.stderr,\n        )\n        print(\"Available columns:\", list(transects.columns), file=sys.stderr)\n        return 1\n\n    transects[id_col] = transects[id_col].astype(str)\n    transects = transects.set_index(id_col)\n\n    print(f\"[merge_linear_models] Using '{id_col}' as transect ID column\")\n    print(f\"[merge_linear_models] Transects rows: {len(transects)}\")\n\n    # --- Flatten all site_models into a DataFrame ---\n    rows = []\n    for path in args.site_models:\n        with open(path, \"r\") as f:\n            data = json.load(f)\n        site_id = data.get(\"site_id\")\n        trends = data.get(\"trends\", {})\n        for transect_id, metrics in trends.items():\n            row = {\n                \"transect_id\": str(transect_id),\n                \"site_id_model\": site_id,\n            }\n            row.update(metrics)\n            rows.append(row)\n\n    if not rows:\n        out_path = \"transects_extended.geojson\"\n        transects.reset_index().to_file(out_path, driver=\"GeoJSON\")\n        print(\"[merge_linear_models] No trends to merge; wrote original transects to\", out_path)\n        return 0\n\n    trends_df = pd.DataFrame(rows)\n    trends_df = trends_df.drop_duplicates(subset=\"transect_id\", keep=\"last\")\n    trends_df = trends_df.set_index(\"transect_id\")\n    trends_df.index = trends_df.index.astype(str)\n\n    print(f\"[merge_linear_models] Loaded {len(args.site_models)} model files\")\n    print(f\"[merge_linear_models] Unique transect_ids in trends: {len(trends_df)}\")\n\n    # --- Join with suffix _new, then selectively overwrite ---\n    trends_new = trends_df.add_suffix(\"_new\")\n    transects_out = transects.join(trends_new, how=\"left\")\n\n    metric_cols = list(trends_df.columns)  # includes site_id_model and all metrics\n    updated_counts = {}\n\n    for col in metric_cols:\n        new_col = col + \"_new\"\n        if new_col not in transects_out.columns:\n            continue\n\n        if col in transects_out.columns:\n            # Overwrite existing values where we have new non-null ones\n            before_nonnull = transects_out[col].notna().sum()\n            transects_out[col] = transects_out[new_col].where(\n                transects_out[new_col].notna(),\n                transects_out[col],\n            )\n            after_nonnull = transects_out[col].notna().sum()\n            updated_counts[col] = (before_nonnull, after_nonnull)\n        else:\n            # Column didn't exist before: just copy\n            transects_out[col] = transects_out[new_col]\n            updated_counts[col] = (0, transects_out[col].notna().sum())\n\n    # Drop all *_new helper columns\n    new_cols = [c for c in transects_out.columns if c.endswith(\"_new\")]\n    transects_out = transects_out.drop(columns=new_cols)\n\n    for col, (before, after) in updated_counts.items():\n        print(f\"[merge_linear_models] '{col}': non-null before={before}, after={after}\")\n\n    if \"trend\" in transects_out.columns:\n        n_nonnull = transects_out[\"trend\"].notna().sum()\n        print(f\"[merge_linear_models] Rows with non-null 'trend' after merge: {n_nonnull}\")\n\n    out_path = \"transects_extended.geojson\"\n    transects_out.reset_index().to_file(out_path, driver=\"GeoJSON\")\n    print(\"[merge_linear_models] Wrote merged transects to\", out_path)\n    return 0\n\n\nif __name__ == \"__main__\":\n    raise SystemExit(main())\n"
                        }
                    ],
                    "class": "InitialWorkDirRequirement"
                }
            ],
            "baseCommand": [
                "python3",
                "merge_linear_models.py"
            ],
            "inputs": [
                {
                    "type": {
                        "type": "array",
                        "items": "File"
                    },
                    "inputBinding": {
                        "prefix": "--site-models",
                        "separate": true
                    },
                    "id": "#merge_linear_models.cwl/site_models"
                },
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--transects-geojson"
                    },
                    "id": "#merge_linear_models.cwl/transects_extended_geojson"
                }
            ],
            "outputs": [
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "transects_extended.geojson"
                    },
                    "id": "#merge_linear_models.cwl/transects_extended_geojson_out"
                }
            ],
            "id": "#merge_linear_models.cwl"
        },
        {
            "class": "CommandLineTool",
            "label": "Merge per-site slope estimates into transects_extended.geojson",
            "requirements": [
                {
                    "listing": [
                        {
                            "entryname": "merge_slopes.py",
                            "entry": "#!/usr/bin/env python3\nimport argparse, json, os, sys\nimport geopandas as gpd\n\ndef main(argv=None):\n    p = argparse.ArgumentParser()\n    p.add_argument(\"--transects-geojson\", required=True)\n    p.add_argument(\"--site-slopes\", nargs=\"+\", required=True)\n    args = p.parse_args(argv)\n\n    transects = gpd.read_file(args.transects_geojson)\n\n    # ensure columns exist\n    for col in [\"beach_slope\", \"cil\", \"ciu\"]:\n        if col not in transects.columns:\n            transects[col] = None\n\n    for path in args.site_slopes:\n        with open(path) as f:\n            data = json.load(f)\n        slopes = data.get(\"slopes\", {})\n        for tid, vals in slopes.items():\n            if tid not in transects.index:\n                continue\n            transects.at[tid, \"beach_slope\"] = vals[\"beach_slope\"]\n            transects.at[tid, \"cil\"] = vals[\"cil\"]\n            transects.at[tid, \"ciu\"] = vals[\"ciu\"]\n\n    out_path = \"transects_extended.geojson\"\n    transects.to_file(out_path)\n    print(f\"Wrote merged transects to {out_path}\")\n    return 0\n\nif __name__ == \"__main__\":\n    raise SystemExit(main())\n"
                        }
                    ],
                    "class": "InitialWorkDirRequirement"
                }
            ],
            "baseCommand": [
                "python3",
                "merge_slopes.py"
            ],
            "inputs": [
                {
                    "type": {
                        "type": "array",
                        "items": "File"
                    },
                    "inputBinding": {
                        "prefix": "--site-slopes"
                    },
                    "id": "#merge_slopes.cwl/site_slopes"
                },
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--transects-geojson"
                    },
                    "id": "#merge_slopes.cwl/transects_extended_geojson"
                }
            ],
            "outputs": [
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "transects_extended.geojson"
                    },
                    "id": "#merge_slopes.cwl/transects_extended_geojson_out"
                }
            ],
            "id": "#merge_slopes.cwl"
        },
        {
            "class": "CommandLineTool",
            "label": "Estimate beach slope for a single NZ site",
            "requirements": [
                {
                    "listing": [
                        {
                            "entryname": "slope_estimation_site.py",
                            "entry": "#!/usr/bin/env python3\nimport argparse, json, os, sys\n\nimport pandas as pd\nimport geopandas as gpd\nimport numpy as np\nimport pytz\nfrom datetime import datetime\nimport SDS_slope  # provided as SDS_slope.py in this workdir\n\ndef main(argv=None):\n    p = argparse.ArgumentParser()\n    p.add_argument(\"--site-id\", required=True)\n    p.add_argument(\"--site-dir\", required=True)\n    p.add_argument(\"--transects-geojson\", required=True)\n    args = p.parse_args(argv)\n\n    site_id = args.site_id\n    site_dir = os.path.abspath(args.site_dir)\n\n    # Load transects and subset to this site\n    transects = gpd.read_file(args.transects_geojson)\n    new_transects = transects[transects.site_id == site_id].copy()\n    if new_transects.empty:\n        # Nothing to do, write empty JSON\n        out = {\"site_id\": site_id, \"slopes\": {}}\n        with open(f\"slopes_{site_id}.json\", \"w\") as f:\n            json.dump(out, f)\n        return 0\n\n    # Load time series + tides for this site\n    ts_path = os.path.join(site_dir, \"transect_time_series.csv\")\n    tides_path = os.path.join(site_dir, \"tides.csv\")\n    df = pd.read_csv(ts_path)\n    df.index = pd.to_datetime(df[\"dates\"])\n    df = df.drop(columns=[\"dates\", \"satname\"])\n    tides = pd.read_csv(tides_path)\n    tides[\"dates\"] = pd.to_datetime(tides[\"dates\"])\n    tides = tides.set_index(\"dates\")\n    # align/round as in notebook\n    df.index = df.index.round(\"10min\")\n    assert all(df.index == tides.index)\n\n    # Slope settings (as per notebook)\n    seconds_in_day = 24 * 3600\n    settings_slope = {\n        \"slope_min\": 0.01,\n        \"slope_max\": 0.2,\n        \"delta_slope\": 0.005,\n        \"date_range\": [1999, 2020],\n        \"n_days\": 8,\n        \"n0\": 50,\n        \"freqs_cutoff\": 1.0 / (seconds_in_day * 30),\n        \"delta_f\": 100 * 1e-10,\n        \"prc_conf\": 0.05,\n    }\n    settings_slope[\"date_range\"] = [\n        pytz.utc.localize(datetime(settings_slope[\"date_range\"][0], 5, 1)),\n        pytz.utc.localize(datetime(settings_slope[\"date_range\"][1], 1, 1)),\n    ]\n\n    # This mirrors what the notebook did before calling integrate_power_spectrum.\n    freqs_max = SDS_slope.find_tide_peak(\n        df.index,                 # datetime index of shoreline series\n        tides[\"tide\"].to_numpy(), # NIWA tide levels\n        settings_slope,\n    )\n    settings_slope[\"freqs_max\"] = freqs_max\n\n    beach_slopes = SDS_slope.range_slopes(\n        settings_slope[\"slope_min\"],\n        settings_slope[\"slope_max\"],\n        settings_slope[\"delta_slope\"],\n    )\n\n    slope_est = {}\n    cis = {}\n    t = np.array([_.timestamp() for _ in df.index]).astype(\"float64\")\n\n    for key in df.columns:\n        # Match notebook logic: skip NaNs\n        idx_nan = np.isnan(df[key])\n        if np.all(idx_nan):\n            continue\n        dates = [df.index[_] for _ in np.where(~idx_nan)[0]]\n        tide = tides[\"tide\"].to_numpy()[~idx_nan]\n        composite = df[key][~idx_nan]\n\n        tsall = SDS_slope.tide_correct(composite, tide, beach_slopes)\n        s, ci = SDS_slope.integrate_power_spectrum(\n            dates, tsall, settings_slope\n        )\n        slope_est[key] = float(s)\n        cis[key] = [float(ci[0]), float(ci[1])]\n\n    result = {\n        \"site_id\": site_id,\n        \"slopes\": {\n            k: {\"beach_slope\": slope_est[k], \"cil\": cis[k][0], \"ciu\": cis[k][1]}\n            for k in slope_est.keys()\n        },\n    }\n\n    with open(f\"slopes_{site_id}.json\", \"w\") as f:\n        json.dump(result, f, indent=2)\n\n    return 0\n\nif __name__ == \"__main__\":\n    raise SystemExit(main())\n"
                        },
                        {
                            "entryname": "SDS_slope.py",
                            "entry": "$(inputs.sds_slope.contents)"
                        }
                    ],
                    "class": "InitialWorkDirRequirement"
                }
            ],
            "baseCommand": [
                "python3",
                "slope_estimation_site.py"
            ],
            "inputs": [
                {
                    "type": "File",
                    "loadContents": true,
                    "default": {
                        "class": "File",
                        "location": "file:///Users/eller/Projects/CoastSat-CWL/CoastSat-CWL/tools/slope_estimation_site/SDS_slope.py"
                    },
                    "id": "#slope_estimation_site.cwl/sds_slope"
                },
                {
                    "type": "Directory",
                    "inputBinding": {
                        "prefix": "--site-dir"
                    },
                    "id": "#slope_estimation_site.cwl/site_dir"
                },
                {
                    "type": "string",
                    "inputBinding": {
                        "prefix": "--site-id"
                    },
                    "id": "#slope_estimation_site.cwl/site_id"
                },
                {
                    "type": "File",
                    "inputBinding": {
                        "prefix": "--transects-geojson"
                    },
                    "id": "#slope_estimation_site.cwl/transects_extended_geojson"
                }
            ],
            "outputs": [
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "$( \"slopes_\" + inputs.site_id + \".json\" )"
                    },
                    "id": "#slope_estimation_site.cwl/site_slopes"
                }
            ],
            "id": "#slope_estimation_site.cwl"
        },
        {
            "class": "CommandLineTool",
            "label": "Apply tidal correction for a single NZ site",
            "doc": "Given a site_id, transects_extended.geojson, and a per-site directory\ncontaining transect_time_series.csv and tides.csv, apply tidal correction\nusing the per-transect beach slopes and write\ntransect_time_series_tidally_corrected.csv.\n\nIntended to be scattered over NZD site IDs, after:\n  1. batch_process_nz.cwl (produces transect_time_series.csv)\n  2. fetch_tides_nz_site.cwl (produces tides.csv)\n  3. slope_estimation.cwl (fills beach_slope, cil, ciu in transects_extended.geojson)\n",
            "requirements": [
                {
                    "class": "InitialWorkDirRequirement",
                    "listing": [
                        {
                            "entryname": "apply_tidal_correction_nz_site.py",
                            "entry": "#!/usr/bin/env python3\nimport os\nimport sys\nimport argparse\nimport shutil\nimport warnings\n\nimport numpy as np\nimport pandas as pd\nimport geopandas as gpd\nfrom coastsat import SDS_transects\n\nwarnings.filterwarnings(\"ignore\")\n\n\ndef despike(series: pd.Series, threshold: float = 40.0) -> pd.Series:\n    \"\"\"\n    Apply CoastSat-style despiking to a 1D time series using\n    SDS_transects.identify_outliers.\n\n    Returns a new Series with the same index; non-outlier values\n    are kept, outliers are removed.\n    \"\"\"\n    chainage = series.dropna()\n    if chainage.empty:\n        return series\n\n    cleaned, dates = SDS_transects.identify_outliers(\n        chainage.tolist(), chainage.index.to_list(), threshold\n    )\n\n    out = pd.Series(index=series.index, dtype=\"float64\")\n    out.loc[dates] = cleaned\n    return out\n\n\ndef main(argv=None) -> int:\n    parser = argparse.ArgumentParser(\n        description=\"Apply tidal correction for a single NZ site.\"\n    )\n    parser.add_argument(\n        \"--site-id\",\n        required=True,\n        help=\"Site ID (e.g. nzd0001)\",\n    )\n    parser.add_argument(\n        \"--transects-geojson\",\n        required=True,\n        help=\"Path to transects_extended.geojson (with beach_slope per transect).\",\n    )\n    parser.add_argument(\n        \"--site-dir\",\n        required=True,\n        help=(\n            \"Per-site directory containing transect_time_series.csv \"\n            \"and tides.csv for this site.\"\n        ),\n    )\n\n    args = parser.parse_args(argv)\n\n    site_id = args.site_id\n    site_dir_in = os.path.abspath(args.site_dir)\n\n    ts_path = os.path.join(site_dir_in, \"transect_time_series.csv\")\n    tides_path = os.path.join(site_dir_in, \"tides.csv\")\n\n    if not os.path.isfile(ts_path):\n        print(f\"[{site_id}] Missing transect_time_series.csv, skipping\", file=sys.stderr)\n        return 0\n\n    if not os.path.isfile(tides_path):\n        print(f\"[{site_id}] Missing tides.csv, skipping\", file=sys.stderr)\n        return 0\n\n    # Load transects with slopes\n    transects = gpd.read_file(args.transects_geojson)\n    if \"site_id\" not in transects.columns:\n        print(\n            \"transects_extended.geojson must contain a 'site_id' column.\",\n            file=sys.stderr,\n        )\n        return 1\n\n    transects_at_site = transects[transects[\"site_id\"] == site_id]\n    if transects_at_site.empty:\n        print(\n            f\"[{site_id}] No transects found in transects_extended.geojson, skipping.\",\n            file=sys.stderr,\n        )\n        return 0\n\n    if \"beach_slope\" not in transects_at_site.columns:\n        print(\n            f\"[{site_id}] beach_slope column missing in transects_extended.geojson.\",\n            file=sys.stderr,\n        )\n        return 1\n\n    # Index transects by 'id' so we can match columns to transect IDs\n    transects_at_site = transects_at_site.set_index(\"id\")\n\n    print(f\"[{site_id}] Found {len(transects_at_site)} transects at this site.\", file=sys.stderr)\n\n    # Load raw intersections\n    raw = pd.read_csv(ts_path)\n    if \"dates\" not in raw.columns:\n        print(f\"[{site_id}] 'dates' column missing in transect_time_series.csv\", file=sys.stderr)\n        return 1\n\n    raw[\"dates\"] = pd.to_datetime(raw[\"dates\"])\n    raw.set_index(\"dates\", inplace=True)\n    raw.index = raw.index.round(\"10min\")\n\n    # Load tides and align to raw index\n    tides = pd.read_csv(tides_path)\n    if \"dates\" not in tides.columns or \"tide\" not in tides.columns:\n        print(\n            f\"[{site_id}] tides.csv must have 'dates' and 'tide' columns.\",\n            file=sys.stderr,\n        )\n        return 1\n\n    tides[\"dates\"] = pd.to_datetime(tides[\"dates\"])\n    tides.set_index(\"dates\", inplace=True)\n    tides = tides.sort_index()\n    tides = tides[~tides.index.duplicated(keep=\"first\")]\n\n    # Reindex tides to raw index and interpolate if necessary\n    tides_aligned = tides.reindex(raw.index)\n    if tides_aligned[\"tide\"].isna().any():\n        tides_aligned[\"tide\"] = tides_aligned[\"tide\"].interpolate().bfill().ffill()\n\n    # Identify transect columns (everything except satname)\n    transect_cols = [c for c in raw.columns if c != \"satname\"]\n\n    # Build slopes Series aligned to transect columns\n    slopes = transects_at_site[\"beach_slope\"].astype(\"float64\")\n    slopes = slopes.sort_index() # Sort to make interpolation deterministic along some alongshore order              \n    slopes = slopes.interpolate().bfill().ffill() # Interpolate and fill missing slopes (just to stay 1:1 with the notebook)\n    slopes = slopes.reindex(transect_cols) # Reindex to match the columns\n\n\n    # Build tidal correction DataFrame\n    corrections = pd.DataFrame(index=raw.index, columns=transect_cols, dtype=\"float64\")\n\n    tide_vals = tides_aligned[\"tide\"].to_numpy(dtype=\"float64\")\n\n    for col in transect_cols:\n        slope = slopes.get(col)\n        if slope is None or np.isnan(slope) or slope == 0:\n            # No slope \u2192 no correction for this transect\n            continue\n        # Horizontal correction along transect = tide / slope\n        corrections[col] = tide_vals / slope\n\n    # Fill any remaining NaNs in corrections with 0 (no correction)\n    corrections = corrections.fillna(0.0)\n\n    # Apply corrections\n    corrected = raw.copy()\n    corrected[transect_cols] = corrected[transect_cols] + corrections[transect_cols]\n\n    # Despike per transect (excluding satname)\n    corrected_no_sat = corrected.drop(columns=\"satname\", errors=\"ignore\")\n    corrected_no_sat = corrected_no_sat.apply(despike, axis=0)\n    corrected_no_sat.index.name = \"dates\"\n\n    # Re-add satname if present\n    if \"satname\" in raw.columns:\n        corrected_no_sat[\"satname\"] = raw[\"satname\"]\n\n    # Prepare output directory: ./<site_id> relative to CWL outdir\n    out_site_dir = os.path.join(os.getcwd(), site_id)\n    os.makedirs(out_site_dir, exist_ok=True)\n\n    # Copy original files for convenience/continuity\n    shutil.copy2(ts_path, os.path.join(out_site_dir, \"transect_time_series.csv\"))\n    shutil.copy2(tides_path, os.path.join(out_site_dir, \"tides.csv\"))\n\n    out_csv = os.path.join(out_site_dir, \"transect_time_series_tidally_corrected.csv\")\n    corrected_no_sat.to_csv(out_csv, float_format='%.2f')\n\n    print(f\"[{site_id}] Wrote tidally corrected time series to {out_csv}\", file=sys.stderr)\n    return 0\n\n\nif __name__ == \"__main__\":\n    raise SystemExit(main())\n"
                        }
                    ]
                }
            ],
            "baseCommand": [
                "python3",
                "apply_tidal_correction_nz_site.py"
            ],
            "inputs": [
                {
                    "type": "Directory",
                    "doc": "Per-site directory containing transect_time_series.csv and tides.csv",
                    "inputBinding": {
                        "prefix": "--site-dir",
                        "valueFrom": "$(self.path)"
                    },
                    "id": "#tidal_correction_nz.cwl/site_dir_in"
                },
                {
                    "type": "string",
                    "doc": "Site ID, e.g. nzd0001",
                    "inputBinding": {
                        "prefix": "--site-id"
                    },
                    "id": "#tidal_correction_nz.cwl/site_id"
                },
                {
                    "type": "File",
                    "doc": "Updated transects_extended.geojson with beach_slope values",
                    "inputBinding": {
                        "prefix": "--transects-geojson"
                    },
                    "id": "#tidal_correction_nz.cwl/transects_extended_geojson"
                }
            ],
            "stdout": "apply_tidal_correction.log",
            "outputs": [
                {
                    "type": "Directory",
                    "doc": "Per-site directory containing transect_time_series.csv, tides.csv, and transect_time_series_tidally_corrected.csv.\n",
                    "outputBinding": {
                        "glob": "$(inputs.site_id)"
                    },
                    "id": "#tidal_correction_nz.cwl/site_dir"
                },
                {
                    "type": "File",
                    "doc": "Tidally corrected time series for this site.",
                    "outputBinding": {
                        "glob": "$(inputs.site_id + \"/transect_time_series_tidally_corrected.csv\")"
                    },
                    "id": "#tidal_correction_nz.cwl/transect_time_series_tidally_corrected"
                }
            ],
            "id": "#tidal_correction_nz.cwl"
        },
        {
            "class": "CommandLineTool",
            "doc": "Example CommandLineTool that:\n- receives GEE private key JSON and NIWA_TIDE_API_KEY as inputs\n- writes the GEE key to a temporary file\n- sets GOOGLE_APPLICATION_CREDENTIALS and NIWA_TIDE_API_KEY\n- prints a simple confirmation (no secrets are printed)\n",
            "baseCommand": [
                "python3",
                "use_gee_secrets.py"
            ],
            "requirements": [
                {
                    "listing": [
                        {
                            "entryname": "use_gee_secrets.py",
                            "entry": "#!/usr/bin/env python3\nimport json\nimport os\nimport sys\nimport tempfile\n\ndef main():\n    # Inputs come in via positional arguments\n    gee_key_json = sys.argv[1]\n    niwa_tide_api_key = sys.argv[2]\n\n    # Write the GEE JSON to a temporary file\n    fd, key_path = tempfile.mkstemp(prefix=\"gee-key-\", suffix=\".json\")\n    os.close(fd)\n    with open(key_path, \"w\") as f:\n        f.write(gee_key_json)\n\n    # Export the environment variables for any downstream processes\n    os.environ[\"GOOGLE_APPLICATION_CREDENTIALS\"] = key_path\n    os.environ[\"NIWA_TIDE_API_KEY\"] = niwa_tide_api_key\n\n    # Example of how you *might* load and use the key\n    # (replace this with ee.ServiceAccountCredentials, etc.)\n    with open(key_path, \"r\") as f:\n        key_data = json.load(f)\n    client_email = key_data.get(\"client_email\", \"<missing>\")\n\n    # IMPORTANT: don't print the secrets themselves.\n    # Just confirm that things are wired up.\n    print(\"GEE key loaded for client_email:\", client_email)\n    print(\"GOOGLE_APPLICATION_CREDENTIALS set to:\", key_path)\n    print(\"NIWA_TIDE_API_KEY is set (value not shown).\")\n\nif __name__ == \"__main__\":\n    main()\n"
                        }
                    ],
                    "class": "InitialWorkDirRequirement"
                }
            ],
            "inputs": [
                {
                    "type": "string",
                    "inputBinding": {
                        "position": 1
                    },
                    "id": "#use_gee_secrets.cwl/gee_key_json"
                },
                {
                    "type": "string",
                    "inputBinding": {
                        "position": 2
                    },
                    "id": "#use_gee_secrets.cwl/niwa_tide_api_key"
                }
            ],
            "stdout": "credentials_summary.txt",
            "outputs": [
                {
                    "type": "File",
                    "outputBinding": {
                        "glob": "credentials_summary.txt"
                    },
                    "id": "#use_gee_secrets.cwl/credentials_summary"
                }
            ],
            "id": "#use_gee_secrets.cwl"
        },
        {
            "class": "Workflow",
            "doc": "Workflow to extract nzd and sar site lists from polygons.geojson\nand make them available as string[] arrays for subsequent processing steps.\n",
            "label": "Prepare Workflow Sites",
            "requirements": [
                {
                    "class": "InlineJavascriptRequirement"
                }
            ],
            "inputs": [
                {
                    "type": "File",
                    "doc": "GeoJSON file containing polygon features with site IDs",
                    "id": "#prepare_workflow_sites.cwl/polygons_geojson"
                }
            ],
            "outputs": [
                {
                    "type": {
                        "type": "array",
                        "items": "string"
                    },
                    "outputSource": "#prepare_workflow_sites.cwl/get_nzd_sar/nzd_list",
                    "doc": "List of NZD site IDs ready for handoff to subsequent steps",
                    "id": "#prepare_workflow_sites.cwl/nzd_list"
                },
                {
                    "type": {
                        "type": "array",
                        "items": "string"
                    },
                    "outputSource": "#prepare_workflow_sites.cwl/get_nzd_sar/sar_list",
                    "doc": "List of SAR site IDs ready for handoff to subsequent steps",
                    "id": "#prepare_workflow_sites.cwl/sar_list"
                }
            ],
            "steps": [
                {
                    "run": "#get_nzd_sar_lists.cwl",
                    "in": [
                        {
                            "source": "#prepare_workflow_sites.cwl/read_array/grouped_ids_array",
                            "id": "#prepare_workflow_sites.cwl/get_nzd_sar/grouped_ids_array"
                        }
                    ],
                    "out": [
                        "#prepare_workflow_sites.cwl/get_nzd_sar/nzd_list",
                        "#prepare_workflow_sites.cwl/get_nzd_sar/sar_list"
                    ],
                    "id": "#prepare_workflow_sites.cwl/get_nzd_sar"
                },
                {
                    "run": "#group_by_prefix.cwl",
                    "in": [
                        {
                            "source": "#prepare_workflow_sites.cwl/polygons_geojson",
                            "id": "#prepare_workflow_sites.cwl/group_ids/polygons_geojson"
                        }
                    ],
                    "out": [
                        "#prepare_workflow_sites.cwl/group_ids/grouped_ids"
                    ],
                    "id": "#prepare_workflow_sites.cwl/group_ids"
                },
                {
                    "run": "#read_grouped_ids_array_expr.cwl",
                    "in": [
                        {
                            "source": "#prepare_workflow_sites.cwl/read_array_file/grouped_ids_array_file",
                            "id": "#prepare_workflow_sites.cwl/read_array/grouped_ids_array_file"
                        }
                    ],
                    "out": [
                        "#prepare_workflow_sites.cwl/read_array/grouped_ids_array"
                    ],
                    "id": "#prepare_workflow_sites.cwl/read_array"
                },
                {
                    "run": "#read_grouped_ids_array.cwl",
                    "in": [
                        {
                            "source": "#prepare_workflow_sites.cwl/group_ids/grouped_ids",
                            "id": "#prepare_workflow_sites.cwl/read_array_file/grouped_ids_json"
                        }
                    ],
                    "out": [
                        "#prepare_workflow_sites.cwl/read_array_file/grouped_ids_array_file"
                    ],
                    "id": "#prepare_workflow_sites.cwl/read_array_file"
                }
            ],
            "id": "#prepare_workflow_sites.cwl"
        },
        {
            "class": "Workflow",
            "hints": [
                {
                    "secrets": [
                        "#main/gee_key_json",
                        "#main/niwa_tide_api_key"
                    ],
                    "class": "http://commonwl.org/cwltool#Secrets"
                }
            ],
            "doc": "Example workflow demonstrating parallel processing with scatter-gather.\n\nThis workflow:\n1. Prepares site lists (nzd_list, sar_list) using prepare_workflow_sites\n2. Processes each site ID in parallel using scatter\n3. Collects all results before proceeding\n\nThe scatter pattern allows:\n- Parallel processing of nzd_list and sar_list (separate scatter steps)\n- Parallel processing of each site within each list\n- Automatic collection/waiting for all processes to complete\n",
            "label": "Example Parent Workflow with Parallel Processing",
            "requirements": [
                {
                    "class": "InlineJavascriptRequirement"
                },
                {
                    "class": "SubworkflowFeatureRequirement"
                },
                {
                    "class": "ScatterFeatureRequirement"
                },
                {
                    "class": "MultipleInputFeatureRequirement"
                }
            ],
            "inputs": [
                {
                    "type": "string",
                    "doc": "Full GEE service account JSON as a string.\n(e.g., the contents of your key file)\n",
                    "id": "#main/gee_key_json"
                },
                {
                    "type": "string",
                    "doc": "NIWA tide API key as a plain string.\n",
                    "id": "#main/niwa_tide_api_key"
                },
                {
                    "type": "File",
                    "doc": "GeoJSON file containing polygon features with site IDs",
                    "id": "#main/polygons_geojson"
                },
                {
                    "type": "File",
                    "loadContents": true,
                    "default": {
                        "class": "File",
                        "location": "file:///Users/eller/Projects/CoastSat-CWL/CoastSat-CWL/tools/slope_estimation_site/SDS_slope.py"
                    },
                    "id": "#main/sds_slope"
                },
                {
                    "type": "File",
                    "doc": "GeoJSON file containing shoreline features with site IDs",
                    "id": "#main/shoreline_geojson"
                },
                {
                    "type": "Directory",
                    "doc": "Directory conatining the existing data for each of these sites.",
                    "id": "#main/transect_time_series_per_site"
                },
                {
                    "type": "File",
                    "doc": "GeoJSON file containing transects features with site IDs",
                    "id": "#main/transects_extended_geojson"
                }
            ],
            "outputs": [
                {
                    "type": "File",
                    "outputSource": "#main/load_creds/credentials_summary",
                    "doc": "Simple text summary confirming that secrets were loaded and env vars set.\n",
                    "id": "#main/credentials_summary"
                },
                {
                    "type": {
                        "type": "array",
                        "items": "Directory"
                    },
                    "outputSource": "#main/make_xlsx_nzd/site_dir_out",
                    "doc": "Per-site directories each containing transect_time_series.csv, tides.csv, and transect_time_series_tidally_corrected.csv.\n",
                    "id": "#main/nzd_results"
                },
                {
                    "type": {
                        "type": "array",
                        "items": "Directory"
                    },
                    "outputSource": "#main/clean_sar_sites/site_dir",
                    "doc": "Per-site directories each containing transect_time_series.csv, tides.csv, and transect_time_series_tidally_corrected.csv.\n",
                    "id": "#main/sar_results"
                },
                {
                    "type": "File",
                    "outputSource": "#main/merge_linear_models/transects_extended_geojson_out",
                    "doc": "The final transect_extended data with linear regression estimations\n",
                    "id": "#main/transects_extended"
                },
                {
                    "type": "File",
                    "outputSource": "#main/make_transects_summary/transects_xlsx",
                    "doc": "The global transects summary in Excel format.\n",
                    "id": "#main/transects_summary"
                }
            ],
            "steps": [
                {
                    "run": "#tidal_correction_nz.cwl",
                    "scatter": [
                        "#main/apply_nzd_tidal_correction/site_id",
                        "#main/apply_nzd_tidal_correction/site_dir_in"
                    ],
                    "scatterMethod": "dotproduct",
                    "in": [
                        {
                            "source": "#main/fetch_nzd_tides/site_dir",
                            "id": "#main/apply_nzd_tidal_correction/site_dir_in"
                        },
                        {
                            "source": "#main/prepare_sites/nzd_list",
                            "id": "#main/apply_nzd_tidal_correction/site_id"
                        },
                        {
                            "source": "#main/merge_slopes/transects_extended_geojson_out",
                            "id": "#main/apply_nzd_tidal_correction/transects_extended_geojson"
                        }
                    ],
                    "out": [
                        "#main/apply_nzd_tidal_correction/site_dir",
                        "#main/apply_nzd_tidal_correction/transect_time_series_tidally_corrected"
                    ],
                    "id": "#main/apply_nzd_tidal_correction"
                },
                {
                    "run": "#clean_sar_site_dir.cwl",
                    "scatter": [
                        "#main/clean_sar_sites/site_id",
                        "#main/clean_sar_sites/src_dir"
                    ],
                    "scatterMethod": "dotproduct",
                    "in": [
                        {
                            "source": "#main/prepare_sites/sar_list",
                            "id": "#main/clean_sar_sites/site_id"
                        },
                        {
                            "source": "#main/linear_models_sar/site_dir_out",
                            "id": "#main/clean_sar_sites/src_dir"
                        }
                    ],
                    "out": [
                        "#main/clean_sar_sites/site_dir"
                    ],
                    "id": "#main/clean_sar_sites"
                },
                {
                    "run": "#fetch_tides_nz_site.cwl",
                    "scatter": [
                        "#main/fetch_nzd_tides/site_id",
                        "#main/fetch_nzd_tides/site_dir_in"
                    ],
                    "scatterMethod": "dotproduct",
                    "in": [
                        {
                            "source": "#main/transect_time_series_per_site",
                            "id": "#main/fetch_nzd_tides/existing_root"
                        },
                        {
                            "source": "#main/niwa_tide_api_key",
                            "id": "#main/fetch_nzd_tides/niwa_tide_api_key"
                        },
                        {
                            "source": "#main/polygons_geojson",
                            "id": "#main/fetch_nzd_tides/polygons_geojson"
                        },
                        {
                            "source": "#main/process_nzd_sites/site_dir",
                            "id": "#main/fetch_nzd_tides/site_dir_in"
                        },
                        {
                            "source": "#main/prepare_sites/nzd_list",
                            "id": "#main/fetch_nzd_tides/site_id"
                        }
                    ],
                    "out": [
                        "#main/fetch_nzd_tides/site_dir",
                        "#main/fetch_nzd_tides/tides_csv"
                    ],
                    "doc": "Fetches (or completes) tides.csv for each NZD site using the NIWA API.\nProduces per-site directories containing transect_time_series.csv and tides.csv.\n",
                    "id": "#main/fetch_nzd_tides"
                },
                {
                    "run": "#linear_models_site.cwl",
                    "scatter": [
                        "#main/linear_models_nzd/site_id",
                        "#main/linear_models_nzd/site_dir"
                    ],
                    "scatterMethod": "dotproduct",
                    "in": [
                        {
                            "source": "#main/apply_nzd_tidal_correction/site_dir",
                            "id": "#main/linear_models_nzd/site_dir"
                        },
                        {
                            "source": "#main/prepare_sites/nzd_list",
                            "id": "#main/linear_models_nzd/site_id"
                        }
                    ],
                    "out": [
                        "#main/linear_models_nzd/site_models"
                    ],
                    "id": "#main/linear_models_nzd"
                },
                {
                    "run": "#linear_models_site.cwl",
                    "scatter": [
                        "#main/linear_models_sar/site_id",
                        "#main/linear_models_sar/site_dir"
                    ],
                    "scatterMethod": "dotproduct",
                    "in": [
                        {
                            "source": "#main/process_sar_sites/site_dir",
                            "id": "#main/linear_models_sar/site_dir"
                        },
                        {
                            "source": "#main/prepare_sites/sar_list",
                            "id": "#main/linear_models_sar/site_id"
                        }
                    ],
                    "out": [
                        "#main/linear_models_sar/site_models",
                        "#main/linear_models_sar/site_dir_out"
                    ],
                    "id": "#main/linear_models_sar"
                },
                {
                    "run": "#use_gee_secrets.cwl",
                    "in": [
                        {
                            "source": "#main/gee_key_json",
                            "id": "#main/load_creds/gee_key_json"
                        },
                        {
                            "source": "#main/niwa_tide_api_key",
                            "id": "#main/load_creds/niwa_tide_api_key"
                        }
                    ],
                    "out": [
                        "#main/load_creds/credentials_summary"
                    ],
                    "id": "#main/load_creds"
                },
                {
                    "run": "#make_transects_summary.cwl",
                    "in": [
                        {
                            "source": "#main/merge_linear_models/transects_extended_geojson_out",
                            "id": "#main/make_transects_summary/transects_extended_geojson"
                        }
                    ],
                    "out": [
                        "#main/make_transects_summary/transects_xlsx"
                    ],
                    "id": "#main/make_transects_summary"
                },
                {
                    "run": "#make_xlsx_site.cwl",
                    "scatter": [
                        "#main/make_xlsx_nzd/site_id",
                        "#main/make_xlsx_nzd/site_dir"
                    ],
                    "scatterMethod": "dotproduct",
                    "in": [
                        {
                            "source": "#main/apply_nzd_tidal_correction/site_dir",
                            "id": "#main/make_xlsx_nzd/site_dir"
                        },
                        {
                            "source": "#main/prepare_sites/nzd_list",
                            "id": "#main/make_xlsx_nzd/site_id"
                        },
                        {
                            "source": "#main/merge_linear_models/transects_extended_geojson_out",
                            "id": "#main/make_xlsx_nzd/transects_extended_geojson"
                        }
                    ],
                    "out": [
                        "#main/make_xlsx_nzd/site_xlsx",
                        "#main/make_xlsx_nzd/site_dir_out"
                    ],
                    "id": "#main/make_xlsx_nzd"
                },
                {
                    "run": "#merge_linear_models.cwl",
                    "in": [
                        {
                            "source": [
                                "#main/linear_models_nzd/site_models",
                                "#main/linear_models_sar/site_models"
                            ],
                            "linkMerge": "merge_flattened",
                            "id": "#main/merge_linear_models/site_models"
                        },
                        {
                            "source": "#main/merge_slopes/transects_extended_geojson_out",
                            "id": "#main/merge_linear_models/transects_extended_geojson"
                        }
                    ],
                    "out": [
                        "#main/merge_linear_models/transects_extended_geojson_out"
                    ],
                    "id": "#main/merge_linear_models"
                },
                {
                    "run": "#merge_slopes.cwl",
                    "in": [
                        {
                            "source": "#main/slope_estimation_site/site_slopes",
                            "id": "#main/merge_slopes/site_slopes"
                        },
                        {
                            "source": "#main/transects_extended_geojson",
                            "id": "#main/merge_slopes/transects_extended_geojson"
                        }
                    ],
                    "out": [
                        "#main/merge_slopes/transects_extended_geojson_out"
                    ],
                    "id": "#main/merge_slopes"
                },
                {
                    "run": "#prepare_workflow_sites.cwl",
                    "in": [
                        {
                            "source": "#main/polygons_geojson",
                            "id": "#main/prepare_sites/polygons_geojson"
                        }
                    ],
                    "out": [
                        "#main/prepare_sites/nzd_list",
                        "#main/prepare_sites/sar_list"
                    ],
                    "id": "#main/prepare_sites"
                },
                {
                    "run": "#batch_process_nz.cwl",
                    "scatter": "#main/process_nzd_sites/site_id",
                    "scatterMethod": "dotproduct",
                    "in": [
                        {
                            "source": "#main/gee_key_json",
                            "id": "#main/process_nzd_sites/gee_key_json"
                        },
                        {
                            "source": "#main/polygons_geojson",
                            "id": "#main/process_nzd_sites/polygons_geojson"
                        },
                        {
                            "source": "#main/shoreline_geojson",
                            "id": "#main/process_nzd_sites/shoreline_geojson"
                        },
                        {
                            "source": "#main/prepare_sites/nzd_list",
                            "id": "#main/process_nzd_sites/site_id"
                        },
                        {
                            "source": "#main/transect_time_series_per_site",
                            "id": "#main/process_nzd_sites/transect_time_series_per_site"
                        },
                        {
                            "source": "#main/transects_extended_geojson",
                            "id": "#main/process_nzd_sites/transects_extended_geojson"
                        }
                    ],
                    "out": [
                        "#main/process_nzd_sites/transect_time_series",
                        "#main/process_nzd_sites/site_dir"
                    ],
                    "doc": "Processes each NZD site ID in parallel using the batch_process_nz tool.\nEach scattered run produces a transect_time_series.csv file for that site.\n",
                    "id": "#main/process_nzd_sites"
                },
                {
                    "run": "#batch_process_sar.cwl",
                    "scatter": "#main/process_sar_sites/site_id",
                    "scatterMethod": "dotproduct",
                    "in": [
                        {
                            "source": "#main/gee_key_json",
                            "id": "#main/process_sar_sites/gee_key_json"
                        },
                        {
                            "source": "#main/polygons_geojson",
                            "id": "#main/process_sar_sites/polygons_geojson"
                        },
                        {
                            "source": "#main/shoreline_geojson",
                            "id": "#main/process_sar_sites/shoreline_geojson"
                        },
                        {
                            "source": "#main/prepare_sites/sar_list",
                            "id": "#main/process_sar_sites/site_id"
                        },
                        {
                            "source": "#main/transect_time_series_per_site",
                            "id": "#main/process_sar_sites/transect_time_series_per_site"
                        },
                        {
                            "source": "#main/transects_extended_geojson",
                            "id": "#main/process_sar_sites/transects_extended_geojson"
                        }
                    ],
                    "out": [
                        "#main/process_sar_sites/transect_time_series",
                        "#main/process_sar_sites/site_dir"
                    ],
                    "doc": "Processes each SAR site ID in parallel using the batch_process_sar tool.\nEach scattered run produces a per-site directory containing transect_time_series.csv.\n",
                    "id": "#main/process_sar_sites"
                },
                {
                    "run": "#slope_estimation_site.cwl",
                    "scatter": [
                        "#main/slope_estimation_site/site_id",
                        "#main/slope_estimation_site/site_dir"
                    ],
                    "scatterMethod": "dotproduct",
                    "in": [
                        {
                            "source": "#main/sds_slope",
                            "id": "#main/slope_estimation_site/sds_slope"
                        },
                        {
                            "source": "#main/fetch_nzd_tides/site_dir",
                            "id": "#main/slope_estimation_site/site_dir"
                        },
                        {
                            "source": "#main/prepare_sites/nzd_list",
                            "id": "#main/slope_estimation_site/site_id"
                        },
                        {
                            "source": "#main/transects_extended_geojson",
                            "id": "#main/slope_estimation_site/transects_extended_geojson"
                        }
                    ],
                    "out": [
                        "#main/slope_estimation_site/site_slopes"
                    ],
                    "id": "#main/slope_estimation_site"
                }
            ],
            "id": "#main"
        }
    ],
    "cwlVersion": "v1.2",
    "$namespaces": {
        "cwltool": "http://commonwl.org/cwltool#"
    }
}