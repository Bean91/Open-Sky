from herbie import Herbie
from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed, Future
import threading
import time
import pandas as pd
import xarray as xr
import numpy as np

_cache: dict[str, tuple[xr.Dataset, datetime]] | None = None
_map_cache: tuple[xr.Dataset, tuple[datetime, int]] | None = None

_refresh_lock = threading.Lock()
_map_refresh_lock = threading.Lock()
_background_thread: threading.Thread | None = None
_map_background_thread: threading.Thread | None = None

MAX_CONCURRENT_FETCHES = 24
BACKGROUND_REFRESH_INTERVAL_SECONDS = 300
GEFS_MEMBERS_TO_FETCH = 10
MIN_GEFS_MEMBERS = 8

class ForecastNotReadyError(Exception):
    """Raised when no request has ever successfully populated the cache yet."""

HRRR_SEARCH = "(?:TMP:2 m above ground|UGRD:10 m above ground|VGRD:10 m above ground|APCP|DPT:2 m above ground|PRES:surface|TCDC:entire atmosphere)"
ECMWF_SEARCH = ":2t:|:10u:|:10v:|:tp:sfc:|:2d:|:sp:|:tcc:sfc:"
GEFS_SEARCH = ":APCP:"

GEFS_PUBLISH_LAG = timedelta(hours=4.5)
HRRR_NOWCAST_PUBLISH_LAG = timedelta(hours=2)
HRRR_EXTENDED_PUBLISH_LAG = timedelta(hours=4)
ECMWF_PUBLISH_LAG = timedelta(hours=8)
GFS_PUBLISH_LAG = timedelta(hours=4)

FORECAST_WINDOW_DAYS = 14
COVERAGE_MARGIN_HOURS = 25

GLOBAL_MAP_SEARCH_GROUPS = [
    ({"t2m", "d2m", "sp", "tp"}, r"(?::TMP:2 m above ground:\d+ hour fcst:|:DPT:2 m above ground:\d+ hour fcst:|:PRES:surface:\d+ hour fcst:|:APCP:surface:0-\d+ (?:hour|day) acc fcst:)"),
    ({"u10", "v10", "tcc"}, r"(?::UGRD:10 m above ground:\d+ hour fcst:|:VGRD:10 m above ground:\d+ hour fcst:|:TCDC:entire atmosphere:\d+ hour fcst:)"),
]
GLOBAL_MAP_FIELDS = {"t2m", "u10", "v10", "tp", "d2m", "sp", "tcc"}
GLOBAL_MAP_FORECAST_HOURS = 12
GLOBAL_MAP_GRID_STRIDE = 2

MODELS = {"hrrr_nowcast": "curvilinear","hrrr_extended": "curvilinear", "ifs": "regular", "aifs": "regular"}
SYNOPTIC_MODELS = {"hrrr_extended", "ifs", "aifs", "gefs"}
BACKFILL_MODELS = {"hrrr_extended", "gefs"}
LAG_TABLE = {
    "hrrr_nowcast": HRRR_NOWCAST_PUBLISH_LAG,
    "hrrr_extended": HRRR_EXTENDED_PUBLISH_LAG,
    "ifs": ECMWF_PUBLISH_LAG,
    "aifs": ECMWF_PUBLISH_LAG,
    "gefs": GEFS_PUBLISH_LAG,
}

def _floor_to_hour(t: datetime) -> datetime:
    return t.replace(minute=0, second=0, microsecond=0)

def _floor_to_synoptic_hour(t: datetime) -> datetime:
    return t.replace(hour=(t.hour // 6) * 6, minute=0, second=0, microsecond=0)

def _earliest_coverage_needed(now: datetime) -> datetime:
    return _floor_to_hour(now) - timedelta(hours=COVERAGE_MARGIN_HOURS)

def _latest_run_time(model: str, now: datetime) -> datetime:
    lagged = now - LAG_TABLE[model]
    if model in SYNOPTIC_MODELS:
        run_time = _floor_to_synoptic_hour(lagged)
        if model in BACKFILL_MODELS:
            earliest_needed = _earliest_coverage_needed(now)
            while run_time > earliest_needed:
                run_time -= timedelta(hours=6)
        return run_time
    return _floor_to_hour(lagged)

def _is_cache_stale(cache: dict[str, tuple[xr.Dataset, datetime]] | None, now: datetime) -> dict[str, bool]:
    if cache is None: return {"hrrr_nowcast": True, "hrrr_extended": True, "ifs": True, "aifs": True, "gefs": True}

    _stale_data: dict[str, bool] = {}
    for model in MODELS:
        _stale_data[model] = cache[model][1] != _latest_run_time(model, now)
    _stale_data["gefs"] = "gefs" not in cache or cache["gefs"][1] != _latest_run_time("gefs", now)
    return _stale_data

def _fetch_one(date: datetime, model: str, product: str | None, fxx: int, search: str, **kwargs) -> xr.Dataset:
    H = Herbie(date=date, model=model, product=product, fxx=fxx, **kwargs)
    result = H.xarray(search)
    if isinstance(result, list):
        result = [
            ds.expand_dims("step") if "step" in ds.coords and ds.coords["step"].ndim == 0 else ds
            for ds in result
        ]
        result = xr.merge(result, compat="override", join="outer")
        if "valid_time" in result.coords and "time" in result.coords and "step" in result.dims:
            result = result.assign_coords(valid_time=("step", result.coords["time"].values + result.coords["step"].values))
    return result

def _harmonize_coords_for_concat(datasets: list[xr.Dataset]) -> list[xr.Dataset]:
    if not datasets:
        return datasets
    dim_names = set(datasets[0].dims)
    common_coords = set(datasets[0].coords)
    for ds in datasets[1:]:
        common_coords &= set(ds.coords)
    keep = common_coords | dim_names
    return [ds.drop_vars([c for c in ds.coords if c not in keep]) for ds in datasets]

def _harmonize_and_concat(datasets: list[xr.Dataset], dim: str) -> xr.Dataset:
    return xr.concat(_harmonize_coords_for_concat(datasets), dim=dim, join="outer", coords="different", compat="equals")

def _dataset_missing_field(ds: xr.Dataset, expected_vars: set[str]) -> bool:
    for var in expected_vars:
        if var not in ds.data_vars or bool(ds[var].isnull().all()):
            return True
    return False

def _refresh_global_map() -> None:
    global _map_cache

    now = datetime.now(timezone.utc).replace(tzinfo=None)
    gfs_run_time = _floor_to_synoptic_hour(now - GFS_PUBLISH_LAG)
    fxx_start = int(np.ceil((now - gfs_run_time).total_seconds() / 3600))
    cache_key = (gfs_run_time, fxx_start)

    if _map_cache is not None and _map_cache[1] == cache_key:
        return

    with _map_refresh_lock:
        if _map_cache is not None and _map_cache[1] == cache_key:
            return

        fxx_values = list(range(fxx_start, fxx_start + GLOBAL_MAP_FORECAST_HOURS + 1))
        group_parts: dict[int, list[tuple[int, xr.Dataset]]] = {g: [] for g in range(len(GLOBAL_MAP_SEARCH_GROUPS))}

        with ThreadPoolExecutor(max_workers=MAX_CONCURRENT_FETCHES) as pool:
            futures = {
                pool.submit(_fetch_one, gfs_run_time, "gfs", "pgrb2.0p25", fxx, search): (fxx, group_idx)
                for fxx in fxx_values
                for group_idx, (_, search) in enumerate(GLOBAL_MAP_SEARCH_GROUPS)
            }
            for fut in as_completed(futures):
                fxx, group_idx = futures[fut]
                expected_vars, _ = GLOBAL_MAP_SEARCH_GROUPS[group_idx]
                try:
                    result = fut.result()
                    got_vars = set(result.data_vars)
                    if not expected_vars.issubset(got_vars):
                        print(f"Global map refresh: fxx={fxx} group={group_idx} only returned {sorted(got_vars)}, expected {sorted(expected_vars)} — dropping this hour.")
                        continue
                    group_parts[group_idx].append((fxx, result))
                except Exception as e:
                    print(f"Global map refresh: fetch failed for gfs fxx={fxx} group={group_idx}: {e}")

        common_fxx = set(fxx_values)
        for parts in group_parts.values():
            common_fxx &= {fxx for fxx, _ in parts}

        if len(common_fxx) < len(fxx_values) * 0.75:
            got = {g: len(parts) for g, parts in group_parts.items()}
            print(f"Global map refresh: only {len(common_fxx)}/{len(fxx_values)} hours common to all field groups {got} — keeping previous cache.")
            return

        group_datasets = [
            _harmonize_and_concat(
                [ds for fxx, ds in sorted(parts, key=lambda pair: pair[0]) if fxx in common_fxx],
                dim="step",
            )
            for parts in group_parts.values()
        ]
        dataset = xr.merge(group_datasets, compat="override", join="outer")

        if bool(dataset["valid_time"].isnull().any()):
            print("Global map refresh: merged valid_time has missing timestamps — keeping previous cache.")
            return

        if _dataset_missing_field(dataset, GLOBAL_MAP_FIELDS):
            print("Global map refresh: a field is missing/entirely-null across the fetched range — keeping previous cache.")
            return

        dataset = dataset.isel(
            latitude=slice(None, None, GLOBAL_MAP_GRID_STRIDE),
            longitude=slice(None, None, GLOBAL_MAP_GRID_STRIDE),
        ).load()

        _map_cache = (dataset, cache_key)

def _refresh_cached_forecast() -> None:
    global _cache

    now: datetime = datetime.now(timezone.utc).replace(tzinfo=None)

    if not any(_is_cache_stale(_cache, now).values()):
        return

    with _refresh_lock:
        _stale_data: dict[str, bool] = _is_cache_stale(_cache, now)
        if not any(_stale_data.values()):
            return

        if _cache is None:
            _cache = {}

        _model_table: dict[str, tuple[tuple[str, str | None], tuple[tuple[int, int], float], str]] = {
            "hrrr_nowcast": (("hrrr", "subh"), ((0, 19), 1), HRRR_SEARCH),
            "hrrr_extended": (("hrrr", "sfc"), ((0, 49), 1), HRRR_SEARCH),
            "ifs": (("ifs", "oper"), ((45, 147), 3), ECMWF_SEARCH),
            "aifs": (("aifs", "oper"), ((138, 366), 6), ECMWF_SEARCH),
        }

        run_times: dict[str, datetime] = {}
        futures: dict[Future, tuple[str, str, int]] = {}

        with ThreadPoolExecutor(max_workers=MAX_CONCURRENT_FETCHES) as pool:
            for model, ((herbie_model, product), (fxx_bounds, fxx_step), search) in _model_table.items():
                if not _stale_data.get(model):
                    continue
                run_time = _latest_run_time(model, now)
                run_times[model] = run_time
                for i in range(fxx_bounds[0], fxx_bounds[1], fxx_step):
                    fut = pool.submit(_fetch_one, run_time, herbie_model, product, i, search)
                    futures[fut] = ("model", model, i)

            if _stale_data.get("gefs", True):
                gefs_run_time = _latest_run_time("gefs", now)
                run_times["gefs"] = gefs_run_time
                gefs_fxx_range = list(range(6, 366, 6))
                gefs_members = [f"p{i:02d}" for i in range(1, GEFS_MEMBERS_TO_FETCH + 1)]
                for member in gefs_members:
                    for i in gefs_fxx_range:
                        fut = pool.submit(_fetch_one, gefs_run_time, "gefs", "atmos.5", i, GEFS_SEARCH, member=member, priority=["aws"])
                        futures[fut] = ("gefs", member, i)

            model_parts: dict[str, list[tuple[int, xr.Dataset]]] = {}
            gefs_parts: dict[str, list[tuple[int, xr.Dataset]]] = {}

            for fut in as_completed(futures):
                kind, key, fxx = futures[fut]
                try:
                    result = fut.result()
                except Exception as e:
                    print(f"Forecast refresh: fetch failed for {kind}={key} fxx={fxx}: {e}")
                    continue
                parts = model_parts if kind == "model" else gefs_parts
                parts.setdefault(key, []).append((fxx, result))

        for model in _model_table:
            if model not in model_parts:
                continue
            ordered = [ds for _, ds in sorted(model_parts[model], key=lambda pair: pair[0])]
            model_dataset = _harmonize_and_concat(ordered, dim="step").load()

            expected_vars = {"t2m", "u10", "v10", "tp", "d2m", "sp"} | (set() if model == "hrrr_nowcast" else {"tcc"})
            if _dataset_missing_field(model_dataset, expected_vars):
                print(f"Forecast refresh: {model} is missing a field across its whole fetched range — keeping previous cache.")
                continue

            _cache[model] = (model_dataset, run_times[model])

        if _stale_data.get("gefs", True):
            member_datasets = []
            for member in sorted(gefs_parts):
                ordered = [ds for _, ds in sorted(gefs_parts[member], key=lambda pair: pair[0])]
                member_datasets.append(_harmonize_and_concat(ordered, dim="step"))

            if len(member_datasets) < MIN_GEFS_MEMBERS:
                print(f"Forecast refresh: GEFS only got {len(member_datasets)}/{GEFS_MEMBERS_TO_FETCH} members — keeping previous cache.")
            else:
                gefs_dataset = _harmonize_and_concat(member_datasets, dim="number").load()
                if _dataset_missing_field(gefs_dataset, {"tp"}):
                    print("Forecast refresh: gefs is missing tp across its whole fetched range — keeping previous cache.")
                else:
                    _cache["gefs"] = (gefs_dataset, run_times["gefs"])

def _stitch(early: pd.DataFrame, late: pd.DataFrame) -> pd.DataFrame:
    cols = ["t2m", "u10", "v10", "tp", "d2m", "sp", "tcc"]

    early_start, early_end = early["time"].min(), early["time"].max()
    late_start, late_end = late["time"].min(), late["time"].max()

    overlap_start = max(early_start, late_start)
    overlap_end = min(early_end, late_end)

    if overlap_start > overlap_end:
        return pd.concat([early, late], ignore_index=True).sort_values("time").reset_index(drop=True)

    before = early[early["time"] < overlap_start] if early_start <= late_start else late[late["time"] < overlap_start]
    after = late[late["time"] > overlap_end] if late_end >= early_end else early[early["time"] > overlap_end]

    e = early.set_index("time")[cols]
    l = late.set_index("time")[cols]

    blend_index = e.index.union(l.index)
    blend_index = blend_index[(blend_index >= overlap_start) & (blend_index <= overlap_end)]

    e_on_blend = e.reindex(e.index.union(blend_index)).sort_index().interpolate("time").reindex(blend_index)
    l_on_blend = l.reindex(l.index.union(blend_index)).sort_index().interpolate("time").reindex(blend_index)

    span = (overlap_end - overlap_start).total_seconds()
    weight = np.array([(t - overlap_start).total_seconds() / span if span > 0 else 1.0 for t in blend_index])
    blended = e_on_blend.mul(1 - weight, axis=0) + l_on_blend.mul(weight, axis=0)
    blended = blended.reset_index().rename(columns={"index": "time"})

    return pd.concat([before, blended, after], ignore_index=True).sort_values("time").reset_index(drop=True)

def _redistribute_flux(raw: pd.Series, target_index: pd.DatetimeIndex) -> pd.Series:
    edges = raw.index
    positions = edges.searchsorted(target_index, side="left")
    valid = (positions >= 1) & (positions <= len(edges) - 1)
    counts = np.bincount(positions[valid], minlength=len(edges))
    share = np.full(len(target_index), np.nan)
    share[valid] = raw.to_numpy()[positions[valid]] / counts[positions[valid]]
    return pd.Series(share, index=target_index).bfill().ffill()

def _background_refresh_loop() -> None:
    while True:
        try:
            _refresh_cached_forecast()
        except Exception as e:
            print(f"Background forecast refresh failed: {e}")
        time.sleep(BACKGROUND_REFRESH_INTERVAL_SECONDS)

def _background_map_refresh_loop() -> None:
    while True:
        try:
            _refresh_global_map()
        except Exception as e:
            print(f"Background global map refresh failed: {e}")
        time.sleep(BACKGROUND_REFRESH_INTERVAL_SECONDS)

def start_background_refresh() -> None:
    global _background_thread, _map_background_thread
    if _background_thread is None:
        _background_thread = threading.Thread(target=_background_refresh_loop, daemon=True, name="forecast-refresh")
        _background_thread.start()
    if _map_background_thread is None:
        _map_background_thread = threading.Thread(target=_background_map_refresh_loop, daemon=True, name="global-map-refresh")
        _map_background_thread.start()

def get_forecast(lat: float, lon: float) -> pd.DataFrame:
    now: datetime = datetime.now(timezone.utc).replace(tzinfo=None)
    located_dict: dict[str, pd.DataFrame] = {}
    fcst_df: pd.DataFrame = pd.DataFrame()

    if _cache is None or any(model not in _cache for model in MODELS):
        raise ForecastNotReadyError("forecast cache has not finished its first refresh yet")

    for model, grid_type in MODELS.items():
        ds = _cache[model][0]
        point = None
        if grid_type == "regular":
            point = ds.sel(latitude=lat, longitude=lon, method="nearest")
        elif grid_type == "curvilinear":
            lat2d = ds.latitude.values
            lon2d = ds.longitude.values % 360.0
            dist2 = (lat2d - lat) ** 2 + (lon2d - (lon % 360.0)) ** 2
            iy, ix = np.unravel_index(np.argmin(dist2), dist2.shape)
            point = ds.isel(y=int(iy), x=int(ix))

        cols = ["t2m", "u10", "v10", "tp", "d2m", "sp"] + ([] if model == "hrrr_nowcast" else ["tcc"])
        located_dict[model] = (
            point[cols].to_dataframe().reset_index()
            .drop(columns=["time"])
            .rename(columns={"valid_time": "time"})[["time"] + cols]
        )

        if model in ("ifs", "aifs"):
            located_dict[model] = located_dict[model].sort_values("time")
            located_dict[model]["tp"] = located_dict[model]["tp"] * 1000
            located_dict[model]["tp"] = located_dict[model]["tp"].diff().fillna(located_dict[model]["tp"]).clip(lower=0)
            located_dict[model]["tcc"] = located_dict[model]["tcc"] * 100

        located_dict[model] = located_dict[model].sort_values("time").drop_duplicates(subset="time", keep="first").reset_index(drop=True)
        filled = located_dict[model].set_index("time")[cols].interpolate("time").bfill().ffill()
        located_dict[model][cols] = filled.to_numpy()

    if "gefs" in _cache:
        gefs_ds = _cache["gefs"][0]
        gefs_point = gefs_ds.sel(latitude=lat, longitude=lon % 360.0, method="nearest")

        gefs_df = gefs_point.to_dataframe().reset_index().drop(columns=["time"])

        gefs_df = gefs_df.rename(columns={"valid_time": "time", "number": "member"})

        gefs_df = gefs_df.sort_values(["member", "time"])

        gefs_df["tp_chunk"] = gefs_df.groupby("member")["tp"].diff().fillna(gefs_df["tp"]).clip(lower=0)

        THRESHOLD = 0.1
        gefs_df["is_raining"] = np.where(gefs_df["tp_chunk"].isna(), np.nan, gefs_df["tp_chunk"] >= THRESHOLD)

        pop_df = gefs_df.groupby("time")["is_raining"].mean().reset_index()
        pop_df["pop"] = pop_df["is_raining"] * 100
        pop_df = pop_df.drop(columns=["is_raining"])
    else:
        pop_df = pd.DataFrame({"time": pd.Series(dtype="datetime64[ns]"), "pop": pd.Series(dtype="float64")})

    nowcast_times = located_dict["hrrr_nowcast"]["time"]
    extended_tcc = located_dict["hrrr_extended"].set_index("time")["tcc"].sort_index()
    combined_tcc = extended_tcc.reindex(extended_tcc.index.union(nowcast_times)).sort_index()
    combined_tcc = combined_tcc.interpolate("time").bfill().ffill()
    located_dict["hrrr_nowcast"]["tcc"] = combined_tcc.reindex(nowcast_times).to_numpy()

    ordered = ["hrrr_nowcast", "hrrr_extended", "ifs", "aifs"]
    fcst_df = located_dict[ordered[0]]
    for model in ordered[1:]:
        fcst_df = _stitch(fcst_df, located_dict[model])

    start_time = _earliest_coverage_needed(now)
    end_time = _floor_to_hour(now) + timedelta(days=FORECAST_WINDOW_DAYS) + timedelta(hours=COVERAGE_MARGIN_HOURS)
    fcst_df = fcst_df[(fcst_df["time"] >= start_time) & (fcst_df["time"] <= end_time)].reset_index(drop=True)

    value_cols = ["t2m", "u10", "v10", "tp", "d2m", "sp", "tcc"]
    hourly_index = pd.date_range(start=start_time, end=end_time, freq="h")
    raw_indexed = fcst_df.set_index("time")[value_cols]
    target_index = raw_indexed.index.union(hourly_index)

    filled = raw_indexed.drop(columns=["tp"]).reindex(target_index).interpolate("time").bfill().ffill()
    filled["tp"] = _redistribute_flux(raw_indexed["tp"], target_index)
    fcst_df = filled[value_cols].rename_axis("time").reset_index()

    fcst_df = fcst_df.merge(pop_df, on="time", how="left").sort_values("time").reset_index(drop=True)
    fcst_df["pop"] = fcst_df.set_index("time")["pop"].interpolate("time").bfill().ffill().fillna(0).to_numpy()

    return fcst_df

_GLOBAL_MAP_DECIMALS = {"t2m": 1, "d2m": 1, "u10": 2, "v10": 2, "tp": 2, "sp": 0, "tcc": 1}

def get_global_map(field: str) -> dict:
    if field not in GLOBAL_MAP_FIELDS:
        raise ValueError(f"field must be one of {sorted(GLOBAL_MAP_FIELDS)}")

    if _map_cache is None:
        raise ForecastNotReadyError("global map cache has not finished its first refresh yet")

    dataset, _ = _map_cache
    values = dataset[field].values.astype(float)

    if field == "tp":
        delta = np.empty_like(values)
        delta[0] = values[0]
        delta[1:] = np.diff(values, axis=0)
        values = np.clip(delta, 0, None)

    values = np.round(values, _GLOBAL_MAP_DECIMALS[field])
    times = pd.to_datetime(dataset["valid_time"].values)

    return {
        "field": field,
        "lat": np.round(dataset["latitude"].values, 2).tolist(),
        "lon": np.round(dataset["longitude"].values, 2).tolist(),
        "times": [t.strftime("%Y-%m-%dT%H:%M:%SZ") for t in times],
        "values": values.tolist(),
    }