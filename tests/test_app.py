"""Tests for the pump health service. They run on every pull request.

    pytest -v

The service is started in-process with FastAPI's TestClient, so no server,
container or AWS account is needed.
"""
import pytest
from fastapi.testclient import TestClient

from app.main import app

HEALTHY = {"bearing_temp_c": 58.0, "vibration_mm_s": 2.1, "discharge_pressure_bar": 6.0,
           "motor_current_a": 17.5, "hours_since_service": 400.0}
WORN = {"bearing_temp_c": 88.0, "vibration_mm_s": 7.5, "discharge_pressure_bar": 8.4,
        "motor_current_a": 24.0, "hours_since_service": 3900.0}


@pytest.fixture(scope="module")
def client():
    # The with block runs the app's startup, which loads the model. A model
    # file that is missing fails here, before any request is made.
    with TestClient(app) as c:
        yield c


def test_health_is_ok(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_predict_returns_a_verdict(client):
    r = client.post("/predict", json=HEALTHY)
    assert r.status_code == 200
    body = r.json()
    assert 0.0 <= body["failure_probability"] <= 1.0
    assert body["threshold"] == 0.3


def test_worn_pump_scores_higher_than_healthy_one(client):
    healthy = client.post("/predict", json=HEALTHY).json()
    worn = client.post("/predict", json=WORN).json()
    assert worn["failure_probability"] > healthy["failure_probability"]
    assert worn["inspect"] is True


def test_impossible_reading_is_rejected(client):
    r = client.post("/predict", json={**HEALTHY, "vibration_mm_s": -1})
    assert r.status_code == 422
