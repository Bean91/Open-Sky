from datetime import datetime, timedelta, timezone
import threading

import numpy as np
from skyfield.api import load, wgs84, Star
from skyfield.data import hipparcos
from skyfield import almanac
from skyfield.magnitudelib import planetary_magnitude

from forecast import FORECAST_WINDOW_DAYS, COVERAGE_MARGIN_HOURS, _floor_to_hour, _earliest_coverage_needed

class AstronomyNotReadyError(Exception):
    """Raised when the ephemeris/star catalog have not finished loading yet."""

HOURLY_WINDOW_HOURS = 36
STAR_MAGNITUDE_LIMIT = 5.0

PLANETS = {
    "Mercury": "mercury",
    "Venus": "venus",
    "Mars": "mars",
    "Jupiter": "jupiter barycenter",
    "Saturn": "saturn barycenter",
    "Uranus": "uranus barycenter",
    "Neptune": "neptune barycenter",
}

NAMED_STARS: dict[int, str] = {
    32349: "Sirius", 30438: "Canopus", 71683: "Rigil Kentaurus", 69673: "Arcturus",
    91262: "Vega", 24608: "Capella", 24436: "Rigel", 37279: "Procyon",
    7588: "Achernar", 27989: "Betelgeuse", 68702: "Hadar", 97649: "Altair",
    60718: "Acrux", 21421: "Aldebaran", 80763: "Antares", 65474: "Spica",
    37826: "Pollux", 113368: "Fomalhaut", 102098: "Deneb", 62434: "Mimosa",
    49669: "Regulus", 33579: "Adhara", 36850: "Castor", 61084: "Gacrux",
    85927: "Shaula", 25336: "Bellatrix", 25428: "Elnath", 45238: "Miaplacidus",
    26311: "Alnilam", 109268: "Alnair", 26727: "Alnitak", 62956: "Alioth",
    54061: "Dubhe", 15863: "Mirfak", 34444: "Wezen", 86228: "Sargas",
    90185: "Kaus Australis", 41037: "Avior", 67301: "Alkaid", 28360: "Menkalinan",
    82273: "Atria", 31681: "Alhena", 100751: "Peacock", 11767: "Polaris",
    30324: "Mirzam", 46390: "Alphard", 9884: "Hamal", 3419: "Diphda",
    92855: "Nunki", 100453: "Sadr", 87833: "Eltanin", 105199: "Alderamin",
    107315: "Enif", 53910: "Merak", 72607: "Kochab", 86032: "Rasalhague",
    14576: "Algol", 9640: "Almach", 57632: "Denebola", 39429: "Naos",
    25930: "Mintaka", 76267: "Alphecca", 84012: "Sabik", 58001: "Phecda",
    72622: "Zubenelgenubi", 113963: "Markab",
}

_eph = None
_ts = None
_earth = None
_star_positions: Star | None = None
_star_hip: np.ndarray | None = None
_star_mag: np.ndarray | None = None

_ready = threading.Event()
_load_thread: threading.Thread | None = None

def _load() -> None:
    global _eph, _ts, _earth, _star_positions, _star_hip, _star_mag
    eph = load("de421.bsp")
    ts = load.timescale()
    with load.open(hipparcos.URL) as f:
        df = hipparcos.load_dataframe(f)
    df = df[np.isfinite(df["magnitude"]) & (df["magnitude"] <= STAR_MAGNITUDE_LIMIT)]

    _eph = eph
    _ts = ts
    _earth = eph["earth"]
    _star_positions = Star.from_dataframe(df)
    _star_hip = df.index.to_numpy()
    _star_mag = df["magnitude"].to_numpy()
    _ready.set()

def start_background_load() -> None:
    global _load_thread
    if _load_thread is None:
        _load_thread = threading.Thread(target=_load, daemon=True, name="astronomy-load")
        _load_thread.start()

def _require_ready() -> None:
    if not _ready.is_set():
        raise AstronomyNotReadyError("ephemeris and star catalog have not finished loading yet")

def _iso(t) -> str | None:
    if t is None:
        return None
    return t.utc_strftime("%Y-%m-%dT%H:%M:%SZ")

def _parse_iso(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))

def _first_event(observer, target, t0, t1, horizon_degrees=None):
    times, going_up = almanac.find_risings(observer, target, t0, t1, horizon_degrees)
    rise = times[0] if len(times) else None
    times, _ = almanac.find_settings(observer, target, t0, t1, horizon_degrees)
    setting = times[0] if len(times) else None
    return rise, setting

def _all_risings(observer, target, t0, t1, horizon_degrees=None) -> list[str]:
    times, _ = almanac.find_risings(observer, target, t0, t1, horizon_degrees)
    return [_iso(t) for t in times]

def _all_settings(observer, target, t0, t1, horizon_degrees=None) -> list[str]:
    times, _ = almanac.find_settings(observer, target, t0, t1, horizon_degrees)
    return [_iso(t) for t in times]

def _hourly_series(observer, target, hours_t) -> list[dict]:
    astrometric = observer.at(hours_t).observe(target).apparent()
    alt, az, _ = astrometric.altaz()
    return [
        {"time": h.utc_strftime("%Y-%m-%dT%H:%M:%SZ"), "altitude": round(float(a), 2), "azimuth": round(float(z), 2)}
        for h, a, z in zip(hours_t, alt.degrees, az.degrees)
    ]

def _moon_phase_name(fraction: float, waxing: bool) -> str:
    if fraction < 0.02:
        return "New Moon"
    if fraction > 0.98:
        return "Full Moon"
    if 0.48 <= fraction <= 0.52:
        return "First Quarter" if waxing else "Last Quarter"
    if fraction < 0.5:
        return "Waxing Crescent" if waxing else "Waning Crescent"
    return "Waxing Gibbous" if waxing else "Waning Gibbous"

def _star_snapshot(observer, ref_t) -> list[dict]:
    alt, az, _ = observer.at(ref_t).observe(_star_positions).apparent().altaz()
    alt_deg, az_deg = alt.degrees, az.degrees
    visible = alt_deg > -1
    return [
        {
            "hip": int(hip),
            "name": NAMED_STARS.get(int(hip)),
            "magnitude": round(float(mag), 2),
            "altitude": round(float(a), 2),
            "azimuth": round(float(z), 2),
        }
        for hip, mag, a, z, vis in zip(_star_hip, _star_mag, alt_deg, az_deg, visible)
        if vis
    ]

def _moon_snapshot(observer, moon, ref_dt: datetime, ref_t) -> dict:
    alt, az, _ = observer.at(ref_t).observe(moon).apparent().altaz()
    fraction = float(almanac.fraction_illuminated(_eph, "moon", ref_t))
    later_t = _ts.from_datetime(ref_dt + timedelta(hours=6))
    fraction_later = float(almanac.fraction_illuminated(_eph, "moon", later_t))
    waxing = fraction_later >= fraction
    phase_angle = almanac.moon_phase(_eph, ref_t)
    age_days = (float(phase_angle.degrees) / 360.0) * 29.530588853
    distance_km = float(_earth.at(ref_t).observe(moon).distance().km)
    return {
        "altitude": round(float(alt.degrees), 2),
        "azimuth": round(float(az.degrees), 2),
        "phase_name": _moon_phase_name(fraction, waxing),
        "illumination_percent": round(fraction * 100, 1),
        "age_days": round(age_days, 1),
        "distance_km": round(distance_km, 0),
    }

def _planets_snapshot(observer, ref_t) -> list[dict]:
    result = []
    for name, key in PLANETS.items():
        alt, az, _ = observer.at(ref_t).observe(_eph[key]).apparent().altaz()
        result.append({"name": name, "altitude": round(float(alt.degrees), 2), "azimuth": round(float(az.degrees), 2)})
    return result

def get_sky(lat: float, lon: float, day_reference_times: list[str] | None = None) -> dict:
    _require_ready()

    now_dt = datetime.now(timezone.utc)
    now = _ts.from_datetime(now_dt)
    window_end = _ts.from_datetime(now_dt + timedelta(hours=HOURLY_WINDOW_HOURS))
    hour_start = now_dt.replace(minute=0, second=0, microsecond=0)
    hours_t = _ts.utc([hour_start + timedelta(hours=i) for i in range(HOURLY_WINDOW_HOURS + 1)])

    long_start = _earliest_coverage_needed(now_dt)
    long_end = _floor_to_hour(now_dt) + timedelta(days=FORECAST_WINDOW_DAYS) + timedelta(hours=COVERAGE_MARGIN_HOURS)
    long_hour_count = int((long_end - long_start).total_seconds() // 3600) + 1
    long_hours_t = _ts.utc([long_start + timedelta(hours=i) for i in range(long_hour_count)])
    long_t0 = _ts.from_datetime(long_start)
    long_t1 = _ts.from_datetime(long_end)

    ref_dts = (
        [_parse_iso(s) for s in day_reference_times]
        if day_reference_times
        else [now_dt + timedelta(days=i) for i in range(14)]
    )

    topos = wgs84.latlon(lat, lon)
    observer = _earth + topos

    sun = _eph["sun"]
    moon = _eph["moon"]

    twilight_transitions = {
        "astronomical_dawn": (1, 0), "nautical_dawn": (2, 1), "civil_dawn": (3, 2),
        "civil_dusk": (3, 4), "nautical_dusk": (2, 3), "astronomical_dusk": (1, 2),
    }
    twilight_fn = almanac.dark_twilight_day(_eph, topos)
    t_times, t_events = almanac.find_discrete(long_t0, long_t1, twilight_fn)
    twilight_edges: dict[str, list[str]] = {label: [] for label in twilight_transitions}
    prev_level = int(twilight_fn(long_t0))
    for t, e in zip(t_times, t_events):
        for label, (event, prev_event) in twilight_transitions.items():
            if e == event and prev_level == prev_event:
                twilight_edges[label].append(_iso(t))
        prev_level = e

    moon_phase_fn = almanac.moon_phases(_eph)
    long_range_end = _ts.from_datetime(now_dt + timedelta(days=32))
    mp_times, mp_events = almanac.find_discrete(now, long_range_end, moon_phase_fn)
    next_new = next((t for t, e in zip(mp_times, mp_events) if e == 0), None)
    next_full = next((t for t, e in zip(mp_times, mp_events) if e == 2), None)

    planets: list[dict] = []
    for name, key in PLANETS.items():
        body = _eph[key]
        rise, setting = _first_event(observer, body, now, window_end)
        mag = planetary_magnitude(observer.at(now).observe(body).apparent())
        planets.append({
            "name": name,
            "magnitude": round(float(mag), 2),
            "rise": _iso(rise),
            "set": _iso(setting),
            "hourly": _hourly_series(observer, body, long_hours_t),
        })

    snapshots = []
    for ref_dt in ref_dts:
        ref_t = _ts.from_datetime(ref_dt)
        snapshots.append({
            "time": _iso(ref_t),
            "moon": _moon_snapshot(observer, moon, ref_dt, ref_t),
            "planets": _planets_snapshot(observer, ref_t),
            "stars": _star_snapshot(observer, ref_t),
        })

    return {
        "generated_at": _iso(now),
        "sun": {
            "rises": _all_risings(observer, sun, long_t0, long_t1),
            "sets": _all_settings(observer, sun, long_t0, long_t1),
            "civil_dawns": twilight_edges["civil_dawn"],
            "civil_dusks": twilight_edges["civil_dusk"],
            "nautical_dawns": twilight_edges["nautical_dawn"],
            "nautical_dusks": twilight_edges["nautical_dusk"],
            "astronomical_dawns": twilight_edges["astronomical_dawn"],
            "astronomical_dusks": twilight_edges["astronomical_dusk"],
            "hourly": _hourly_series(observer, sun, hours_t),
        },
        "moon": {
            "rises": _all_risings(observer, moon, long_t0, long_t1),
            "sets": _all_settings(observer, moon, long_t0, long_t1),
            "next_new_moon": _iso(next_new),
            "next_full_moon": _iso(next_full),
        },
        "planets": planets,
        "snapshots": snapshots,
    }
