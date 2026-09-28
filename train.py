"""Train the pump failure model and write it to a folder.

    python train.py                # writes model/
    python train.py --out /out     # writes somewhere else, e.g. a mounted volume

A water utility logs five readings from each pump once a day. The question is
whether a pump will fail within the next seven days, so that a crew inspects it
first. The readings are generated here from a fixed seed, so every run on every
machine sees the same data and needs no download.
"""
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import joblib
import numpy as np
import sklearn
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import train_test_split

# The order the model sees its columns in. The service builds rows in this
# order, read from meta.json, so it never keeps its own copy of the list.
FEATURES = [
    "bearing_temp_c",
    "vibration_mm_s",
    "discharge_pressure_bar",
    "motor_current_a",
    "hours_since_service",
]

# Inspecting a healthy pump costs a crew visit. Missing a failing one costs a
# burst main. So the service flags a pump well below a 50% chance.
THRESHOLD = 0.3
SEED = 7


def make_readings(n: int = 20_000, seed: int = SEED):
    rng = np.random.default_rng(seed)
    temp = rng.normal(62, 8, n)
    vibration = rng.lognormal(np.log(2.5), 0.35, n)
    pressure = rng.normal(6.0, 0.8, n)
    current = rng.normal(18, 2.5, n)
    hours = rng.uniform(0, 4000, n)
    logit = (
        -4.2
        + 0.11 * (temp - 62)
        + 0.95 * (vibration - 2.5)
        + 0.6 * np.abs(pressure - 6.0)
        + 0.12 * (current - 18)
        + 0.0007 * (hours - 2000)
    )
    fails = rng.random(n) < 1 / (1 + np.exp(-logit))
    X = np.column_stack([temp, vibration, pressure, current, hours]).round(2)
    return X, fails.astype(int)


def main(out: Path) -> None:
    X, y = make_readings()
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.25, stratify=y, random_state=SEED
    )
    model = HistGradientBoostingClassifier(max_iter=200, learning_rate=0.05, random_state=SEED)
    model.fit(X_train, y_train)
    auc = roc_auc_score(y_test, model.predict_proba(X_test)[:, 1])

    out.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, out / "model.joblib")
    meta = {
        "model_version": datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"),
        "sklearn_version": sklearn.__version__,
        "features": FEATURES,
        "threshold": THRESHOLD,
        "test_roc_auc": round(float(auc), 4),
        "failure_rate": round(float(y.mean()), 4),
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(f"trained on {len(y_train)} readings, failure rate {y.mean():.1%}")
    print(f"test ROC AUC {auc:.4f}, wrote {out}/model.joblib and {out}/meta.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path("model"))
    main(parser.parse_args().out)
