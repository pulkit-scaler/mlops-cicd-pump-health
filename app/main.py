"""The pump health service.

    uvicorn app.main:app --host 0.0.0.0 --port 8000

It loads the model once at startup and answers two questions. Is this process
able to score a pump right now, and should this pump be inspected.
"""
import json
import os
from contextlib import asynccontextmanager
from pathlib import Path

import joblib
import numpy as np
import sklearn
from fastapi import FastAPI
from pydantic import BaseModel, Field

# The folder holding model.joblib and meta.json. An environment variable, so a
# container can be pointed at a different model without rebuilding the image.
MODEL_DIR = Path(os.environ.get("MODEL_DIR", Path(__file__).resolve().parents[1] / "model"))

# The commit the image was built from, baked in by `docker build --build-arg GIT_SHA=...`.
# /health reports it, so one request tells you which version is live.
GIT_SHA = os.environ.get("GIT_SHA", "unknown")


class Reading(BaseModel):
    bearing_temp_c: float = Field(ge=-20, le=150)
    vibration_mm_s: float = Field(ge=0, le=50)
    discharge_pressure_bar: float = Field(ge=0, le=20)
    motor_current_a: float = Field(ge=0, le=100)
    hours_since_service: float = Field(ge=0)


class Verdict(BaseModel):
    failure_probability: float
    inspect: bool
    threshold: float
    model_version: str


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.model = joblib.load(MODEL_DIR / "model.joblib")
    app.state.meta = json.loads((MODEL_DIR / "meta.json").read_text())
    yield


app = FastAPI(title="Pump health", version="1.0.0", lifespan=lifespan)


@app.get("/health")
def health():
    meta = app.state.meta
    matches = meta["sklearn_version"] == sklearn.__version__
    return {
        "status": "ok" if matches else "degraded",
        "model_version": meta["model_version"],
        "trained_with_sklearn": meta["sklearn_version"],
        "running_sklearn": sklearn.__version__,
        "git_sha": GIT_SHA,
    }


@app.post("/predict", response_model=Verdict)
def predict(reading: Reading):
    meta = app.state.meta
    row = np.array([[getattr(reading, name) for name in meta["features"]]])
    p = float(app.state.model.predict_proba(row)[0, 1])
    return Verdict(
        failure_probability=round(p, 4),
        inspect=p >= meta["threshold"],
        threshold=meta["threshold"],
        model_version=meta["model_version"],
    )
