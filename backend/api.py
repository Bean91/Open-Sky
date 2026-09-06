from fastapi import FastAPI, Response
from fastapi.middleware.gzip import GZipMiddleware
import pandas as pd
import requests
from forecast import get_forecast, get_global_map, start_background_refresh, ForecastNotReadyError
from tides import get_tides, start_background_station_refresh, TidesNotReadyError
from astronomy import get_sky, start_background_load, AstronomyNotReadyError
from planes import get_planes, get_route, get_aircraft, start_background_feed
from pydantic import BaseModel

app = FastAPI()
app.add_middleware(GZipMiddleware, minimum_size=1000)

@app.on_event("startup")
def _on_startup():
    start_background_refresh()
    start_background_station_refresh()
    start_background_load()
    start_background_feed()

class Location(BaseModel):
    lat: float
    lon: float

class PlaneQuery(BaseModel):
    lat: float
    lon: float
    radius_km: float = 200.0

class SkyLocation(BaseModel):
    lat: float
    lon: float
    day_reference_times: list[str] | None = None

@app.post("/api/get-forecast")
def api_forecast(loc: Location):
    try:
        df = get_forecast(loc.lat, loc.lon)
    except ForecastNotReadyError:
        return Response(status_code=503, content='{"detail":"forecast cache is still warming up, try again shortly"}', media_type="application/json")
    df["time"] = df["time"].dt.tz_localize("UTC")
    return Response(content=df.to_json(orient="records", date_format="iso", date_unit="s"), media_type="application/json")

@app.get("/api/global-map")
def api_global_map(field: str):
    try:
        data = get_global_map(field)
    except ForecastNotReadyError:
        return Response(status_code=503, content='{"detail":"global map cache is still warming up, try again shortly"}', media_type="application/json")
    except ValueError as e:
        return Response(status_code=400, content=f'{{"detail":"{e}"}}', media_type="application/json")
    return data

@app.post("/api/get-tides")
def api_tides(loc: Location):
    try:
        data = get_tides(loc.lat, loc.lon)
    except TidesNotReadyError:
        return Response(status_code=503, content='{"detail":"tide station list is still loading, try again shortly"}', media_type="application/json")
    except ValueError as e:
        return Response(status_code=400, content=f'{{"detail":"{e}"}}', media_type="application/json")
    except requests.RequestException:
        return Response(status_code=502, content='{"detail":"failed to fetch tide data from NOAA"}', media_type="application/json")
    return data

@app.post("/api/get-sky")
def api_sky(loc: SkyLocation):
    try:
        data = get_sky(loc.lat, loc.lon, loc.day_reference_times)
    except AstronomyNotReadyError:
        return Response(status_code=503, content='{"detail":"ephemeris and star catalog are still loading, try again shortly"}', media_type="application/json")
    return data

@app.post("/api/get-planes")
def api_planes(query: PlaneQuery):
    return get_planes(query.lat, query.lon, query.radius_km)

@app.get("/api/get-plane-route")
def api_plane_route(callsign: str):
    route = get_route(callsign)
    if route is None:
        return Response(status_code=404, content='{"detail":"route not found for callsign"}', media_type="application/json")
    return route

@app.get("/api/get-aircraft")
def api_aircraft(hex: str):
    aircraft = get_aircraft(hex)
    if aircraft is None:
        return Response(status_code=404, content='{"detail":"aircraft not found for hex code"}', media_type="application/json")
    return aircraft