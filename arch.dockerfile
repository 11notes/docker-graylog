# ╔═════════════════════════════════════════════════════╗
# ║                       SETUP                         ║
# ╚═════════════════════════════════════════════════════╝
# GLOBAL
  ARG APP_UID=1000 \
      APP_GID=1000 \
      APP_GO_VERSION=0 \
      APP_JAVA_VERSION=21

# :: FOREIGN IMAGES
  FROM 11notes/distroless:localhealth AS distroless-localhealth
  FROM 11notes/distroless AS distroless
  FROM 11notes/util AS util

# ╔═════════════════════════════════════════════════════╗
# ║                       BUILD                         ║
# ╚═════════════════════════════════════════════════════╝
# :: ENTRYPOINT
  FROM 11notes/go:${APP_GO_VERSION} AS entrypoint
  ARG APP_GO_VERSION
  COPY ./build/go/entrypoint /go/entrypoint
  RUN set -ex; \
    eleven go build-entrypoint;

# :: GRAYLOG
  FROM eclipse-temurin:21-jdk-jammy AS build
  COPY --from=util / /
  ARG APP_VERSION \
      BUILD_SRC=https://downloads.graylog.org/releases/graylog/graylog-${APP_VERSION}.tgz \
      BUILD_ROOT=/opt/graylog

  RUN set -eux; \
    apt-get update && apt-get install -y --no-install-recommends \
      curl;

  RUN set -eux; \
    cd /tmp; \
    curl -sSfL -o graylog.tgz ${BUILD_SRC}; \
    curl -sSfL -o graylog.tgz.sha256 ${BUILD_SRC}.sha256.txt; \
    echo "$(cut -d' ' -f1 graylog.tgz.sha256)  graylog.tgz" | sha256sum -c -; \
    mkdir -p ${BUILD_ROOT}; \
    tar --extract --gzip --file graylog.tgz --strip-components=1 --directory ${BUILD_ROOT}; \
    rm -rf ${BUILD_ROOT}/bin ${BUILD_ROOT}/data ${BUILD_ROOT}/graylog.conf.example /tmp/graylog.tgz*;

  RUN set -eux; \
    mkdir -p /tmp/config; \
    for f in graylog.conf log4j2.xml; do \
      curl -sSfL -o /tmp/config/${f} https://raw.githubusercontent.com/Graylog2/graylog-docker/refs/heads/7.2/config/${f}; \
    done;

# :: DISTROLESS JRE
  FROM eclipse-temurin:21-jdk-jammy AS build-jre
  COPY --from=util / /

  RUN set -eux; \
    apt-get update && apt-get install -y --no-install-recommends \
      binutils;

  RUN set -eux; \
    jlink \
      --add-modules java.base,java.compiler,java.desktop,java.instrument,java.logging,java.management,java.management.rmi,java.naming,java.net.http,java.rmi,java.scripting,java.security.jgss,java.security.sasl,java.sql,java.transaction.xa,java.xml,jdk.crypto.cryptoki,jdk.crypto.ec,jdk.localedata,jdk.management,jdk.management.agent,jdk.naming.dns,jdk.net,jdk.security.auth,jdk.unsupported,jdk.zipfs \
      --strip-debug --no-man-pages --no-header-files \
      --output /opt/jre-minimal;

  RUN set -eux; \
    rm -f /opt/jre-minimal/lib/security/cacerts; \
    cp -fL ${JAVA_HOME}/lib/security/cacerts /opt/jre-minimal/lib/security/cacerts;

  RUN set -eux; \
    mkdir -p /opt/libs; \
    { \
      find /opt/jre-minimal -type f \( -name 'java' -o -name '*.so' \) -exec ldd {} \; 2>/dev/null; \
      find /lib /usr/lib -type f -o -type l | grep -E '/(libnss_files|libnss_dns|libresolv)\.so\.2$' | sed 's/$/ => & (0x0)/'; \
    } | awk '{print $(NF-1)}' | grep '^/' | sort -u \
      | while read -r lib; do \
          mkdir -p "/opt/libs$(dirname "$lib")"; \
          cp -L "$lib" "/opt/libs$lib"; \
        done; \
    INTERP=$(readelf -l /opt/jre-minimal/bin/java | grep 'Requesting program interpreter' | sed -E 's/.*: (.*)\]/\1/'); \
    mkdir -p "/opt/libs$(dirname "$INTERP")"; \
    cp -L "$INTERP" "/opt/libs$INTERP"

# :: FILE SYSTEM
  FROM alpine AS file-system
  ARG APP_ROOT
  USER root

  RUN set -eux; \
    mkdir -p /distroless${APP_ROOT}/etc; \
    mkdir -p /distroless${APP_ROOT}/var/journal; \
    mkdir -p /distroless${APP_ROOT}/var/log; \
    mkdir -p /distroless${APP_ROOT}/var/data;

  COPY --from=build /tmp/config/ /distroless${APP_ROOT}/etc/


# ╔═════════════════════════════════════════════════════╗
# ║                       IMAGE                         ║
# ╚═════════════════════════════════════════════════════╝
  # :: HEADER
  FROM scratch

  # :: default arguments
    ARG TARGETPLATFORM \
        TARGETOS \
        TARGETARCH \
        TARGETVARIANT \
        APP_IMAGE \
        APP_NAME \
        APP_VERSION \
        APP_ROOT \
        APP_UID \
        APP_GID \
        APP_NO_CACHE

  # :: default environment
    ENV APP_IMAGE=${APP_IMAGE} \
        APP_NAME=${APP_NAME} \
        APP_VERSION=${APP_VERSION} \
        APP_ROOT=${APP_ROOT}

  # :: app specific environment
    ENV JAVA_HOME=/opt/jre-minimal \
        JAVA_TOOL_OPTIONS="-Dlog4j2.formatMsgNoLookups=true -Djdk.tls.acknowledgeCloseNotify=true -XX:+UnlockExperimentalVMOptions -XX:-OmitStackTraceInFastThrow -XX:+UseG1GC" \
        GRAYLOG_DATA_DIR=${APP_ROOT}/var \
        GRAYLOG_MESSAGE_JOURNAL_DIR=${APP_ROOT}/var/journal \
        GRAYLOG_NODE_ID_FILE=${APP_ROOT}/var/node-id \
        GRAYLOG_PLUGIN_DIR=/opt/graylog/plugin \
        GRAYLOG_MONGODB_URI="mongodb://mongodb:27017/graylog"

  # :: multi-stage
    COPY --from=distroless / /
    COPY --from=distroless-localhealth / /
    COPY --from=build-jre /opt/libs/ /
    COPY --from=build-jre /opt/jre-minimal /opt/jre-minimal
    COPY --from=build --chown=${APP_UID}:${APP_GID} /opt/graylog /opt/graylog
    COPY --from=entrypoint /distroless/ /
    COPY --from=file-system --chown=${APP_UID}:${APP_GID} /distroless/ /

# :: PERSISTENT DATA
  VOLUME ["${APP_ROOT}/etc", "${APP_ROOT}/var"]

# :: MONITORING
  HEALTHCHECK --interval=10s --timeout=2s --start-period=60s --retries=12 \
    CMD ["/usr/local/bin/localhealth", "http://127.0.0.1:9000/api/system/lbstatus"]

# :: EXECUTE
  USER ${APP_UID}:${APP_GID}
  ENTRYPOINT ["/usr/local/bin/entrypoint"]