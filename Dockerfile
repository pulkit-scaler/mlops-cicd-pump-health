# The pump health service, with its model inside.
#
#     docker build --build-arg GIT_SHA=$(git rev-parse HEAD) -t pump-health .
#     docker run -d --name pump-api -p 9000:8000 pump-health

# An exact base, never python:latest. slim is Debian without compilers and docs.
FROM python:3.12-slim

# Every path below is relative to /app inside the image.
WORKDIR /app

# Dependencies before code. This layer is rebuilt only when requirements.txt
# changes, so an edit to app/ does not reinstall scikit-learn.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Code and model last, because they change most often.
COPY train.py .
COPY app/ app/
COPY model/ model/

# The commit this image was built from. Declared after the pip layer, so a new
# commit does not invalidate the cached dependencies.
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

# Documents the port. It publishes nothing; docker run -p does that.
EXPOSE 8000

# 0.0.0.0, not the default 127.0.0.1, or nothing outside the container can connect.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
