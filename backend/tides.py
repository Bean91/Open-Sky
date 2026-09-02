from datetime import datetime, timedelta, timezone
import threading
import time

import numpy as np
import pandas as pd
import requests

from forecast import _earliest_coverage_needed, _floor_to_hour, COVERAGE_MARGIN_HOURS, FORECAST_WINDOW_DAYS

class TidesNotReadyError(Exception):
    """Raised when the tide station list has not loaded yet."""

NOAA_STATIONS_URL = "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json"
NOAA_DATA_URL = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter"

MAX_STATION_DISTANCE_KM = 300

STATION_REFRESH_INTERVAL_SECONDS = 24 * 3600
TIDE_CACHE_TTL_SECONDS = 3600

_station_cache: pd.DataFrame | None = None
_station_lock = threading.Lock()
_station_thread: threading.Thread | None = None

_tide_cache: dict[str, dict] = {}
_tide_cache_lock = threading.Lock()

def _refresh_stations() -> None:
    global _station_cache
    resp = requests.get(NOAA_STATIONS_URL, params={"type": "tidepredictions"}, timeout=30)
    resp.raise_for_status()
    stations = resp.json()["stations"]
    df = pd.DataFrame([{"id": s["id"], "name": s["name"], "lat": s["lat"], "lon": s["lng"]} for s in stations])
    with _station_lock:
        _station_cache = df

def _background_station_refresh_loop() -> None:
    while True:
        try:
            _refresh_stations()
        except Exception as e:
            print(f"Tide station refresh failed: {e}")
        time.sleep(STATION_REFRESH_INTERVAL_SECONDS)

def start_background_station_refresh() -> None:
    global _station_thread
    if _station_thread is None:
        _station_thread = threading.Thread(target=_background_station_refresh_loop, daemon=True, name="tide-station-refresh")
        _station_thread.start()

def _haversine_km(lat1: float, lon1: float, lat2: np.ndarray, lon2: np.ndarray) -> np.ndarray:
    lat1, lon1, lat2, lon2 = np.radians(lat1), np.radians(lon1), np.radians(lat2), np.radians(lon2)
    a = np.sin((lat2 - lat1) / 2) ** 2 + np.cos(lat1) * np.cos(lat2) * np.sin((lon2 - lon1) / 2) ** 2
    return 2 * 6371.0 * np.arcsin(np.sqrt(a))

def _nearest_station(lat: float, lon: float) -> tuple[str, str, float]:
    if _station_cache is None:
        raise TidesNotReadyError("tide station list has not loaded yet")
    dist_km = _haversine_km(lat, lon, _station_cache["lat"].to_numpy(), _station_cache["lon"].to_numpy())
    i = int(np.argmin(dist_km))
    row = _station_cache.iloc[i]
    return str(row["id"]), str(row["name"]), float(dist_km[i])

def _fetch_predictions(station_id: str, begin: datetime, end: datetime, interval: str) -> list[dict]:
    params = {
        "product": "predictions",
        "application": "OpenSky",
        "begin_date": begin.strftime("%Y%m%d %H:%M"),
        "end_date": end.strftime("%Y%m%d %H:%M"),
        "datum": "MLLW",
        "station": station_id,
        "time_zone": "gmt",
        "units": "metric",
        "interval": interval,
        "format": "json",
    }
    resp = requests.get(NOAA_DATA_URL, params=params, timeout=20)
    resp.raise_for_status()
    data = resp.json()
    if "error" in data:
        raise RuntimeError(f"NOAA CO-OPS error for station {station_id}: {data['error'].get('message')}")
    return data.get("predictions", [])

def get_tides(lat: float, lon: float) -> dict:
    station_id, station_name, distance_km = _nearest_station(lat, lon)
    if distance_km > MAX_STATION_DISTANCE_KM:
        raise ValueError(f"no tide station within {MAX_STATION_DISTANCE_KM} km of ({lat}, {lon})")

    now = datetime.now(timezone.utc).replace(tzinfo=None)
    start_time = _earliest_coverage_needed(now)
    end_time = _floor_to_hour(now) + timedelta(days=FORECAST_WINDOW_DAYS) + timedelta(hours=COVERAGE_MARGIN_HOURS)

    with _tide_cache_lock:
        cached = _tide_cache.get(station_id)

    fresh_enough = (
        cached is not None
        and (now - cached["fetched_at"]).total_seconds() < TIDE_CACHE_TTL_SECONDS
        and cached["start"] <= start_time
        and cached["end"] >= end_time
    )

    if not fresh_enough:
        hourly_raw = _fetch_predictions(station_id, start_time, end_time, "h")
        extremes_raw = _fetch_predictions(station_id, start_time, end_time, "hilo")

        hourly_df = pd.DataFrame(hourly_raw)
        hourly_df["time"] = pd.to_datetime(hourly_df["t"])
        hourly_df["height"] = hourly_df["v"].astype(float)
        hourly_df = hourly_df[["time", "height"]].sort_values("time").reset_index(drop=True)

        extremes = sorted(
            (
                {"time": pd.Timestamp(e["t"]), "type": "high" if e["type"] == "H" else "low", "height": float(e["v"])}
                for e in extremes_raw
            ),
            key=lambda e: e["time"],
        )

        cached = {"hourly": hourly_df, "extremes": extremes, "start": start_time, "end": end_time, "fetched_at": now}
        with _tide_cache_lock:
            _tide_cache[station_id] = cached

    hourly_df = cached["hourly"]
    hourly_df = hourly_df[(hourly_df["time"] >= start_time) & (hourly_df["time"] <= end_time)]
    extremes = [e for e in cached["extremes"] if start_time <= e["time"] <= end_time]

    return {
        "station_id": station_id,
        "station_name": station_name,
        "station_distance_km": round(distance_km, 1),
        "datum": "MLLW",
        "units": "meters",
        "hourly": [
            {"time": t.strftime("%Y-%m-%dT%H:%M:%SZ"), "height": round(h, 3)}
            for t, h in zip(hourly_df["time"], hourly_df["height"])
        ],
        "extremes": [
            {"time": e["time"].strftime("%Y-%m-%dT%H:%M:%SZ"), "type": e["type"], "height": round(e["height"], 3)}
            for e in extremes
        ],
    }
