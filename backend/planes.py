import socket
import threading
import time
from datetime import datetime, timezone

import numpy as np
import requests

ADSBHUB_HOST = "data.adsbhub.org"
ADSBHUB_PORT = 5002

STALE_AFTER_SECONDS = 120
RECONNECT_DELAY_SECONDS = 5
PRUNE_INTERVAL_SECONDS = 30

_planes: dict[str, dict] = {}
_planes_lock = threading.Lock()
_feed_thread: threading.Thread | None = None

ADSBDB_ROUTE_URL = "https://api.adsbdb.com/v0/callsign/{}"
ROUTE_CACHE_TTL_SECONDS = 24 * 3600

_route_cache: dict[str, dict] = {}
_route_cache_lock = threading.Lock()

ADSBDB_AIRCRAFT_URL = "https://api.adsbdb.com/v0/aircraft/{}"
AIRCRAFT_CACHE_TTL_SECONDS = 7 * 24 * 3600

_aircraft_cache: dict[str, dict] = {}
_aircraft_cache_lock = threading.Lock()


def _parse_float(value: str) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _parse_int(value: str) -> int | None:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def _handle_message(fields: list[str]) -> None:
    if len(fields) < 22 or fields[0] != "MSG":
        return

    hex_ident = fields[4].strip()
    if not hex_ident:
        return

    now = datetime.now(timezone.utc)

    with _planes_lock:
        plane = _planes.setdefault(hex_ident, {"hex": hex_ident})
        plane["last_seen"] = now

        callsign = fields[10].strip()
        if callsign:
            plane["callsign"] = callsign

        altitude = _parse_int(fields[11])
        if altitude is not None:
            plane["altitude_ft"] = altitude

        ground_speed = _parse_float(fields[12])
        if ground_speed is not None:
            plane["ground_speed_kt"] = ground_speed

        track = _parse_float(fields[13])
        if track is not None:
            plane["track_deg"] = track

        lat = _parse_float(fields[14])
        lon = _parse_float(fields[15])
        if lat is not None and lon is not None:
            plane["lat"] = lat
            plane["lon"] = lon

        vertical_rate = _parse_int(fields[16])
        if vertical_rate is not None:
            plane["vertical_rate_fpm"] = vertical_rate

        on_ground = fields[21].strip()
        if on_ground:
            plane["on_ground"] = on_ground in ("1", "-1", "true", "True")


def _prune_stale() -> None:
    cutoff = datetime.now(timezone.utc).timestamp() - STALE_AFTER_SECONDS
    with _planes_lock:
        stale = [h for h, p in _planes.items() if p["last_seen"].timestamp() < cutoff]
        for h in stale:
            del _planes[h]


def _feed_loop() -> None:
    consecutive_empty_connects = 0
    while True:
        try:
            with socket.create_connection((ADSBHUB_HOST, ADSBHUB_PORT), timeout=30) as sock:
                sock.settimeout(60)
                buffer = ""
                last_prune = time.monotonic()
                received_any = False
                while True:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    received_any = True
                    consecutive_empty_connects = 0
                    buffer += chunk.decode("utf-8", errors="ignore")
                    while "\n" in buffer:
                        line, buffer = buffer.split("\n", 1)
                        line = line.strip()
                        if line:
                            _handle_message(line.split(","))

                    if time.monotonic() - last_prune > PRUNE_INTERVAL_SECONDS:
                        _prune_stale()
                        last_prune = time.monotonic()

                if not received_any:
                    consecutive_empty_connects += 1
                    if consecutive_empty_connects == 1 or consecutive_empty_connects % 12 == 0:
                        print(
                            "ADSBHub closed the connection without sending data "
                            f"({consecutive_empty_connects}x). This IP is likely not whitelisted "
                            "as an active feeder on your ADSBHub profile - see "
                            "https://www.adsbhub.org/howtogetdata.php"
                        )
        except Exception as e:
            print(f"ADSBHub feed error: {e}")
        time.sleep(RECONNECT_DELAY_SECONDS)


def start_background_feed() -> None:
    global _feed_thread
    if _feed_thread is None:
        _feed_thread = threading.Thread(target=_feed_loop, daemon=True, name="adsbhub-feed")
        _feed_thread.start()


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    lat1, lon1, lat2, lon2 = np.radians(lat1), np.radians(lon1), np.radians(lat2), np.radians(lon2)
    a = np.sin((lat2 - lat1) / 2) ** 2 + np.cos(lat1) * np.cos(lat2) * np.sin((lon2 - lon1) / 2) ** 2
    return 2 * 6371.0 * np.arcsin(np.sqrt(a))


def get_planes(lat: float, lon: float, radius_km: float = 200.0, limit: int = 200) -> list[dict]:
    with _planes_lock:
        snapshot = list(_planes.values())

    result = []
    for p in snapshot:
        if "lat" not in p or "lon" not in p:
            continue
        dist = _haversine_km(lat, lon, p["lat"], p["lon"])
        if dist > radius_km:
            continue
        result.append({
            "hex": p["hex"],
            "callsign": p.get("callsign"),
            "lat": p["lat"],
            "lon": p["lon"],
            "altitude_ft": p.get("altitude_ft"),
            "ground_speed_kt": p.get("ground_speed_kt"),
            "track_deg": p.get("track_deg"),
            "vertical_rate_fpm": p.get("vertical_rate_fpm"),
            "on_ground": p.get("on_ground", False),
            "distance_km": round(dist, 1),
            "last_seen": p["last_seen"].strftime("%Y-%m-%dT%H:%M:%SZ"),
        })

    result.sort(key=lambda p: p["distance_km"])
    return result[:limit]


def _airport(raw: dict | None) -> dict | None:
    if not raw:
        return None
    return {
        "icao": raw.get("icao_code"),
        "iata": raw.get("iata_code"),
        "name": raw.get("name"),
        "municipality": raw.get("municipality"),
        "country": raw.get("country_name"),
        "lat": raw.get("latitude"),
        "lon": raw.get("longitude"),
    }


def get_route(callsign: str) -> dict | None:
    callsign = callsign.strip().upper()
    if not callsign:
        return None

    now = time.monotonic()
    with _route_cache_lock:
        cached = _route_cache.get(callsign)
    if cached is not None and now - cached["fetched_at"] < ROUTE_CACHE_TTL_SECONDS:
        return cached["data"]

    data = None
    try:
        resp = requests.get(ADSBDB_ROUTE_URL.format(callsign), timeout=10)
        if resp.status_code == 200:
            payload = resp.json().get("response")
            if isinstance(payload, dict):
                route = payload.get("flightroute")
                if route:
                    data = {
                        "callsign": route.get("callsign"),
                        "airline": (route.get("airline") or {}).get("name"),
                        "origin": _airport(route.get("origin")),
                        "destination": _airport(route.get("destination")),
                    }
    except requests.RequestException as e:
        print(f"adsbdb lookup failed for {callsign}: {e}")

    with _route_cache_lock:
        _route_cache[callsign] = {"data": data, "fetched_at": now}

    return data


def get_aircraft(hex_ident: str) -> dict | None:
    hex_ident = hex_ident.strip().lower()
    if not hex_ident:
        return None

    now = time.monotonic()
    with _aircraft_cache_lock:
        cached = _aircraft_cache.get(hex_ident)
    if cached is not None and now - cached["fetched_at"] < AIRCRAFT_CACHE_TTL_SECONDS:
        return cached["data"]

    data = None
    try:
        resp = requests.get(ADSBDB_AIRCRAFT_URL.format(hex_ident), timeout=10)
        if resp.status_code == 200:
            payload = resp.json().get("response")
            if isinstance(payload, dict):
                aircraft = payload.get("aircraft")
                if aircraft:
                    data = {
                        "type": aircraft.get("type"),
                        "icao_type": aircraft.get("icao_type"),
                        "manufacturer": aircraft.get("manufacturer"),
                        "registration": aircraft.get("registration"),
                        "owner": aircraft.get("registered_owner"),
                        "owner_country": aircraft.get("registered_owner_country_name"),
                        "photo_url": aircraft.get("url_photo"),
                        "photo_thumbnail_url": aircraft.get("url_photo_thumbnail"),
                    }
    except requests.RequestException as e:
        print(f"adsbdb aircraft lookup failed for {hex_ident}: {e}")

    with _aircraft_cache_lock:
        _aircraft_cache[hex_ident] = {"data": data, "fetched_at": now}

    return data
