# clientpatch toolchain: Python (stdlib only) + mpqcli built from its pinned
# source commit. Pins must match clientpatch.toml ([mpq] version_prefix).
FROM debian:trixie-slim AS mpqcli
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git cmake g++ make \
 && rm -rf /var/lib/apt/lists/*
# mpqcli v0.9.9 (MIT); its StormLib submodule is pinned by this commit.
ARG MPQCLI_COMMIT=7b458f54b2ec4904941c04a5a25860d7bb200ca3
RUN git clone https://github.com/TheGrayDot/mpqcli.git /src \
 && git -C /src checkout "${MPQCLI_COMMIT}" \
 && git -C /src submodule update --init --depth 1 \
 && cmake -S /src -B /src/build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /src/build -j"$(nproc)" \
 && /src/build/bin/mpqcli version

FROM python:3.12-slim-trixie
# git: build-info.json records the repository commit of the deltas.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/* \
 && git config --system --add safe.directory '*'
COPY --from=mpqcli /src/build/bin/mpqcli /usr/local/bin/mpqcli
WORKDIR /opt/clientpatch
COPY . .
ENV PYTHONPATH=/opt/clientpatch
ENTRYPOINT ["python3", "-m", "clientpatch"]
CMD ["--help"]
