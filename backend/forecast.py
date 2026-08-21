from herbie import Herbie
from datetime import datetime, timedelta, timezone
import pandas as pd
import xarray as xr
import numpy as np

_cache: dict[str, tuple[xr.Dataset, datetime]] | None = None

HRRR_SEARCH = "(?:TMP:2 m above ground|UGRD:10 m above ground|VGRD:10 m above ground|APCP|DPT:2 m above ground|PRES:surface)"
ECMWF_SEARCH = ":2t:|:10u:|:10v:|:tp:sfc:|:2d:|:sp:"

HRRR_NOWCAST_PUBLISH_LAG = timedelta(hours=2)
HRRR_EXTENDED_PUBLISH_LAG = timedelta(hours=4)
ECMWF_PUBLISH_LAG = timedelta(hours=8)

MODELS = {"hrrr_nowcast": "curvilinear","hrrr_extended": "curvilinear", "ifs": "regular", "aifs": "regular"}
SYNOPTIC_MODELS = {"hrrr_extended", "ifs", "aifs"}
LAG_TABLE = {
    "hrrr_nowcast": HRRR_NOWCAST_PUBLISH_LAG,
    "hrrr_extended": HRRR_EXTENDED_PUBLISH_LAG,
    "ifs": ECMWF_PUBLISH_LAG,
    "aifs": ECMWF_PUBLISH_LAG,
}

def _floor_to_quarter_hour(t: datetime) -> datetime:
    return t.replace(minute=(t.minute // 15) * 15, second=0, microsecond=0)

def _floor_to_hour(t: datetime) -> datetime:
    return t.replace(minute=0, second=0, microsecond=0)

def _floor_to_synoptic_hour(t: datetime) -> datetime:
    return t.replace(hour=(t.hour // 6) * 6, minute=0, second=0, microsecond=0)

def _ceil_to_synoptic_hour(t: datetime) -> datetime:
    floored = t.replace(hour=(t.hour // 6) * 6, minute=0, second=0, microsecond=0)
    if floored < t:
        floored += timedelta(hours=6)
    return floored

def _latest_run_time(model: str, now: datetime) -> datetime:
    lagged = now - LAG_TABLE[model]
    if model in SYNOPTIC_MODELS:
        return _floor_to_synoptic_hour(lagged)
    return _floor_to_hour(lagged)

def _is_cache_stale(cache: dict[str, tuple[xr.Dataset, datetime]] | None, now: datetime) -> dict[str, bool]:
    if cache is None: return {"hrrr_nowcast": True, "hrrr_extended": True, "ifs": True, "aifs": True}

    _stale_data: dict[str, bool] = {}
    for model in MODELS:
        _stale_data[model] = cache[model][1] != _latest_run_time(model, now)
    return _stale_data

def _refresh_cached_forecast() -> None:
    global _cache
    now: datetime = datetime.now(timezone.utc).replace(tzinfo=None)
    _stale_data: dict[str, bool] = _is_cache_stale(_cache, now)
    if _cache is None:
        _cache = {}

    _model_table: dict[str, tuple[tuple[str, str | None], tuple[tuple[int, int], float], str]] = {
        "hrrr_nowcast": (("hrrr", "subh"), ((0, 19), 1), HRRR_SEARCH),
        "hrrr_extended": (("hrrr", "sfc"), ((17, 49), 1), HRRR_SEARCH),
        "ifs": (("ifs", "oper"), ((45, 147), 3), ECMWF_SEARCH),
        "aifs": (("aifs", "oper"), ((138, 258), 6), ECMWF_SEARCH),
    }

    for model, is_stale in _stale_data.items():
        if is_stale:
            run_time = _latest_run_time(model, now)
            datasets = []
            for i in range(_model_table[model][1][0][0], _model_table[model][1][0][1], _model_table[model][1][1]):
                H = Herbie(date=run_time, model=_model_table[model][0][0], product=_model_table[model][0][1], fxx=i)
                result = H.xarray(_model_table[model][2])
                if isinstance(result, list):
                    result = xr.merge(result, compat="override", join="override")
                datasets.append(result)
            _model_dataset = xr.concat(datasets, dim="step")
            _cache[model] = (_model_dataset, run_time)

def _stitch(early: pd.DataFrame, late: pd.DataFrame) -> pd.DataFrame:
    cols = ["t2m", "u10", "v10", "tp", "d2m", "sp"]
    overlap_start = late["time"].min()
    overlap_end = early["time"].max()

    if overlap_start > overlap_end:
        return pd.concat([early, late], ignore_index=True).sort_values("time").reset_index(drop=True)

    before = early[early["time"] < overlap_start]
    after = late[late["time"] > overlap_end]

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


def get_forecast(lat: float, lon: float) -> pd.DataFrame:
    now: datetime = datetime.now(timezone.utc).replace(tzinfo=None)
    located_dict: dict[str, pd.DataFrame] = {}
    fcst_df: pd.DataFrame = pd.DataFrame()

    _refresh_cached_forecast()

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

        located_dict[model] = point[["t2m", "u10", "v10", "tp", "d2m", "sp"]].to_dataframe().reset_index().drop(columns=["time"]).rename(columns={"valid_time": "time"})

        if model in ("ifs", "aifs"):
            located_dict[model] = located_dict[model].sort_values("time")
            located_dict[model]["tp"] = located_dict[model]["tp"].diff().fillna(located_dict[model]["tp"]).clip(lower=0)
    
    ordered = ["hrrr_nowcast", "hrrr_extended", "ifs", "aifs"]
    fcst_df = located_dict[ordered[0]]
    for model in ordered[1:]:
        fcst_df = _stitch(fcst_df, located_dict[model])

    start_time = _floor_to_quarter_hour(now)
    end_time = _ceil_to_synoptic_hour(now + timedelta(hours=240))
    fcst_df = fcst_df[(fcst_df["time"] >= start_time) & (fcst_df["time"] <= end_time)].reset_index(drop=True)

    return fcst_df