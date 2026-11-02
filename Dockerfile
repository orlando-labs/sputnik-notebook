# Build from the sibling-repository context produced by tools/container-context.
FROM debian:bookworm-slim AS sdk
ARG BUILD_JOBS=12
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang-19 llvm-19 lld-19 pkg-config libssl-dev libarchive-dev \
    libyaml-dev zlib1g-dev bzip2 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && ! command -v python3 && ! command -v python
RUN curl --fail --location --retry 3 \
    https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.bz2 \
    --output /tmp/pcre2.tar.bz2 \
    && echo '47fe8c99461250d42f89e6e8fdaeba9da057855d06eb7fc08d9ca03fd08d7bc7  /tmp/pcre2.tar.bz2' | sha256sum -c - \
    && cd /tmp && tar -xjf pcre2.tar.bz2 && cd pcre2-10.47 \
    && ./configure --prefix=/opt/pcre2 --enable-unicode --enable-jit --disable-pcre2grep --disable-pcre2test \
    && make -j${BUILD_JOBS} && make install
ENV CXX=clang++-19 SPUTNIK_NATIVE_CXX=clang++-19 SPUTNIK_NATIVE_JOBS=8 \
    SPUTNIK_NATIVE_RT_JOBS=8 PKG_CONFIG_PATH=/opt/pcre2/lib/pkgconfig \
    LD_LIBRARY_PATH=/opt/pcre2/lib
WORKDIR /src
COPY sputnik-lang/ sputnik-lang/
RUN make -C sputnik-lang -j${BUILD_JOBS} build/sputnik

FROM sdk AS build
ARG BUILD_JOBS=12
COPY sqlite3/ sqlite3/
COPY orm/ orm/
COPY orbit/ orbit/
COPY plot/ plot/
COPY sputnik-notebook/ sputnik-notebook/
RUN --mount=type=cache,target=/src/sputnik-notebook/.build/native-runtime \
    SPUTNIK_NATIVE_RT_CACHE=/src/sputnik-notebook/.build/native-runtime \
    make -C sputnik-notebook -j${BUILD_JOBS} remote-core

FROM build AS test
ENV MALLOC_ARENA_MAX=2 SPUTNIK_PKG_HOME=/tmp/sputnik-test-packages
RUN make -C /src/sputnik-notebook test-notebook-remote test-notebook-remote-serve \
    && ! command -v python3 && ! command -v python

FROM debian:bookworm-slim AS runtime
ARG NOTEBOOK_REVISION=unknown
ARG SPUTNIK_REVISION=unknown
LABEL org.opencontainers.image.title="Sputnik Remote Core" \
    org.opencontainers.image.revision=$NOTEBOOK_REVISION \
    io.sputnik.vm.revision=$SPUTNIK_REVISION
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl tini g++ pkg-config libssl-dev libarchive-dev libyaml-dev \
    zlib1g-dev libnuma1 libelf1 libdrm2 libdrm-amdgpu1 libpciaccess0 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 sputnik && useradd --uid 1000 --gid 1000 --create-home sputnik \
    && ! command -v python3 && ! command -v python
COPY --from=test /opt/pcre2 /opt/pcre2
# Retain the SDK at its build location for worker/source-extension compilation.
COPY --from=test /src/sputnik-lang /src/sputnik-lang
COPY --from=test /src/sputnik-notebook/build/sputnik-notebook-remote /usr/local/bin/
COPY --from=test /src/sputnik-notebook/build/sputnik-notebook-worker /usr/local/bin/
COPY --from=test /src/sputnik-notebook/tools/notebook-remote/docker-healthcheck /usr/local/bin/sputnik-notebook-healthcheck
RUN ln -s /src/sputnik-lang/build/sputnik /usr/local/bin/sputnik \
    && mkdir -p /var/lib/sputnik-notebook /var/lib/sputnik-packages /var/cache/sputnik \
    && chown -R sputnik:sputnik /var/lib/sputnik-notebook /var/lib/sputnik-packages /var/cache/sputnik
ENV HOME=/home/sputnik MALLOC_ARENA_MAX=2 \
    SPUTNIK_PKG_HOME=/var/lib/sputnik-packages \
    SPUTNIK_NATIVE_RT_CACHE=/var/cache/sputnik/native-runtime \
    SPUTNIK_NATIVE_EXT_CACHE=/var/cache/sputnik/native-extensions \
    SPUTNIK_NATIVE_CXX=g++ PKG_CONFIG_PATH=/opt/pcre2/lib/pkgconfig \
    LD_LIBRARY_PATH=/opt/pcre2/lib
USER sputnik:sputnik
EXPOSE 18765
VOLUME ["/var/lib/sputnik-notebook", "/var/lib/sputnik-packages", "/var/cache/sputnik"]
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD ["/usr/local/bin/sputnik-notebook-healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/sputnik-notebook-remote"]
CMD ["--mode", "serve", "--host", "0.0.0.0", "--port", "18765", "--root", "/var/lib/sputnik-notebook", "--worker", "/usr/local/bin/sputnik-notebook-worker", "--sputnik", "/usr/local/bin/sputnik"]
