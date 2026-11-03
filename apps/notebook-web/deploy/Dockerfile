ARG SDK_IMAGE=sputnik-release-sdk:1.0.0
FROM ${SDK_IMAGE} AS native
ARG BUILD_JOBS=16
ENV CXX=clang++-19 SPUTNIK_NATIVE_CXX=clang++-19 SPUTNIK_NATIVE_JOBS=8 \
    SPUTNIK_NATIVE_RT_JOBS=8 PKG_CONFIG_PATH=/opt/pcre2/lib/pkgconfig LD_LIBRARY_PATH=/opt/pcre2/lib
WORKDIR /src
COPY sputnik-lang/ sputnik-lang/
RUN make -C sputnik-lang -j${BUILD_JOBS} build/sputnik
RUN make -C sputnik-lang -j${BUILD_JOBS} test-argparser-environment
COPY sqlite3/ sqlite3/
COPY orm/ orm/
COPY orbit/ orbit/
COPY plot/ plot/
COPY sputnik-notebook/Makefile sputnik-notebook/Makefile
COPY sputnik-notebook/mk/ sputnik-notebook/mk/
COPY sputnik-notebook/packages/ sputnik-notebook/packages/
COPY sputnik-notebook/tools/ sputnik-notebook/tools/
COPY sputnik-notebook/tests/ sputnik-notebook/tests/
COPY SOURCE-MANIFEST.json /src/SOURCE-MANIFEST.json
RUN make -C sputnik-notebook -j${BUILD_JOBS} remote-core
COPY sputnik-notebook/apps/notebook-web/ sputnik-notebook/apps/notebook-web/
WORKDIR /src/sputnik-notebook/apps/notebook-web
RUN mkdir -p build/evidence && \
    ../../../sputnik-lang/build/sputnik build backend/main.s -o build/native/notebook-web \
      --target native --require-full-native --grant net.listen --grant net.connect \
      --grant random.secure --grant time.now --grant fs.read --grant fs.write --grant fs.metadata --grant ffi \
      > build/evidence/main-native.json
RUN ../../../sputnik-lang/build/sputnik build tools/public_template.s -o build/native/notebook-public-template \
      --target native --require-full-native --grant net.connect --grant fs.read --grant fs.metadata --grant ffi \
      > build/evidence/public-template-native.json
RUN sh tools/public_test > build/evidence/public-adapter.log 2>&1

FROM node:24-bookworm-slim AS frontend
WORKDIR /frontend
COPY sputnik-notebook/apps/notebook-web/frontend/package.json sputnik-notebook/apps/notebook-web/frontend/package-lock.json ./
RUN npm ci
COPY sputnik-notebook/apps/notebook-web/frontend/ ./
RUN npm run build

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl tini g++ pkg-config libssl-dev libarchive-dev libyaml-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10197 notebook && useradd --uid 10197 --gid 10197 --create-home notebook \
    && ! command -v python3 && ! command -v python
COPY --from=native /opt/pcre2 /opt/pcre2
COPY --from=native /src/sputnik-lang /src/sputnik-lang
COPY --from=native /src/sputnik-notebook/build/sputnik-notebook-remote /usr/local/bin/
COPY --from=native /src/sputnik-notebook/build/sputnik-notebook-worker /usr/local/bin/
COPY --from=native /src/sputnik-notebook/apps/notebook-web/build/native/notebook-web /usr/local/bin/
COPY --from=native /src/sputnik-notebook/apps/notebook-web/build/native/notebook-public-template /usr/local/bin/
COPY --from=native /src/sputnik-notebook/apps/notebook-web/build/evidence/ /opt/notebook-evidence/
COPY --from=native /src/SOURCE-MANIFEST.json /opt/notebook-evidence/SOURCE-MANIFEST.json
COPY --from=native /src/sputnik-lang/build/argparser-environment-native-build.json \
    /src/sputnik-lang/build/argparser-environment-native.out /src/sputnik-lang/build/argparser-environment-vm.out /opt/notebook-evidence/sdk/
COPY sputnik-notebook/apps/notebook-web/db/migrations/ /opt/notebook-web/db/migrations/
COPY --from=frontend /frontend/dist/ /opt/notebook-web/frontend/dist/
COPY sputnik-notebook/apps/notebook-web/deploy/healthcheck /usr/local/bin/notebook-web-healthcheck
RUN ln -s /src/sputnik-lang/build/sputnik /usr/local/bin/sputnik \
    && mkdir -p /var/lib/notebook-core /var/lib/notebook-web /var/lib/notebook-packages /var/cache/notebook \
    && chown -R notebook:notebook /var/lib/notebook-core /var/lib/notebook-web /var/lib/notebook-packages /var/cache/notebook
ENV MALLOC_ARENA_MAX=2 SPUTNIK_PKG_HOME=/var/lib/notebook-packages \
    SPUTNIK_NATIVE_RT_CACHE=/var/cache/notebook/native-runtime SPUTNIK_NATIVE_EXT_CACHE=/var/cache/notebook/native-extensions \
    SPUTNIK_NATIVE_CXX=g++ PKG_CONFIG_PATH=/opt/pcre2/lib/pkgconfig LD_LIBRARY_PATH=/opt/pcre2/lib
WORKDIR /opt/notebook-web
USER 10197:10197
EXPOSE 3000
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD ["sh", "/usr/local/bin/notebook-web-healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/notebook-web"]
CMD ["--mode", "production", "--behind-proxy"]
