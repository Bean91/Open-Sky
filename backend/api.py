from fastapi import FastAPI, Response
from fastapi.middleware.gzip import GZipMiddleware
import pandas as pd
import requests
from forecast import get_forecast, get_global_map, start_background_refresh, ForecastNotReadyError
from tides import get_tides, start_background_station_refresh, TidesNotReadyError
from pydantic import BaseModel

app = FastAPI()
app.add_middleware(GZipMiddleware, minimum_size=1000)

@app.on_event("startup")
def _on_startup():
    start_background_refresh()
    start_background_station_refresh()

class Location(BaseModel):
    lat: float
    lon: float

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