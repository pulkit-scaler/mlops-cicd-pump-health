# Pump health, deployed by a pipeline

Companion code for the session on CI/CD with GitHub Actions.

A water utility logs five readings from each of its pumps once a day. A model
scores the latest readings for the chance that the pump fails within seven
days, and a small FastAPI service answers one question over HTTP: should a
crew inspect this pump first.

This is the same service as in the Docker and ECS sessions, with one addition.
`/health` also reports `git_sha`, the commit the running image was built from,
so a single request tells you which version is live.

## Layout

```
train.py            generates the readings from a fixed seed, fits the model, writes model/
app/main.py         the service: GET /health, POST /predict
model/              model.joblib and meta.json, committed so the image can be built at once
requirements.txt    exact versions, the environment the image freezes
Dockerfile          how the image is built; GIT_SHA is a build argument
.dockerignore       what the build never sees
```

The session adds `.github/workflows/deploy.yml`, which builds the image,
pushes it to Amazon ECR and rolls it out on Amazon ECS on every push to `main`.

## Run it locally

```bash
docker build --build-arg GIT_SHA=$(git rev-parse HEAD) -t pump-health .
docker run -d --name pump-api -p 9000:8000 pump-health
curl -s http://localhost:9000/health
```
