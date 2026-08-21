from fastapi import FastAPI, Response
import pandas as pd
from forecast import get_forecast
from pydantic import BaseModel

app = FastAPI()

class Location(BaseModel):
    lat: float
    lon: float

@app.post("/api/get-forecast")
def api_forecast(loc: Location):
    return Response(content=get_forecast(loc.lat, loc.lon).to_json(orient="records", date_format="iso"), media_type="application/json")