# Dockerfile for DailyCulture API
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# System deps (libpq allows optional Postgres usage)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# If a requirements.txt exists in your project, we'll use it.
# If not, we install a sensible default set of deps.
COPY requirements.txt /tmp/requirements.txt
RUN if [ -f /tmp/requirements.txt ]; then \
      pip install -r /tmp/requirements.txt; \
    else \
      pip install fastapi 'uvicorn[standard]' SQLAlchemy pydantic python-dotenv \
                 'passlib[bcrypt]' 'python-jose[cryptography]' psycopg2-binary; \
    fi

# Copy your app
COPY . .

EXPOSE 8000

# If your file is not app.py or the FastAPI object is not named 'app',
# change the module path here (e.g., main:api)
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
