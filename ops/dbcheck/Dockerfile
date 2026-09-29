# dbcheck: Python (stdlib only) plus the MariaDB command-line client, which is
# the only way the tool talks to a database (read-only SELECTs on stdin).
FROM python:3.12-slim-trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends mariadb-client \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/dbcheck
COPY . .
ENV PYTHONPATH=/opt/dbcheck
ENTRYPOINT ["python3", "-m", "dbcheck"]
CMD ["--help"]
