FROM ubuntu:22.04 AS download
ARG YB_VERSION=2025.2.2.1
ARG YB_BUILD=1
ARG YB_ARCH=x86_64
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates && \
    wget -O /yugabyte.tar.gz \
    "https://downloads.yugabyte.com/releases/${YB_VERSION}/yugabyte-${YB_VERSION}-b${YB_BUILD}-linux-${YB_ARCH}.tar.gz"

FROM scratch
COPY --from=download /yugabyte.tar.gz /tarball/yugabyte.tar.gz
