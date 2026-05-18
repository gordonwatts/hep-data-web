FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DJANGO_SETTINGS_MODULE=hep_data_web.settings.prod

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY pyproject.toml README.md /app/
COPY hep_data_web /app/hep_data_web
COPY portal /app/portal
COPY manage.py /app/manage.py

RUN uv sync --extra dev --frozen

COPY . /app

RUN uv sync --extra dev --frozen

CMD ["uv", "run", "gunicorn", "hep_data_web.wsgi:application", "--bind", "0.0.0.0:8000"]
