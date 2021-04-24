###################################
#Build stage
FROM golang:alpine AS build-env

ARG GOPROXY
ENV GOPROXY ${GOPROXY:-direct}
ENV GO_FLAGS="-tags=libpfm,netgo,libipmctl"

RUN echo "http://dl-cdn.alpinelinux.org/alpine/edge/community/" >> /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing/" >> /etc/apk/repositories && \
    apk update && \
    apk --update add libc6-compat device-mapper findutils zfs build-base \
    linux-headers go python3 bash git wget cmake pkgconfig ndctl-dev thin-provisioning-tools && \
    echo 'hosts: files mdns4_minimal [NOTFOUND=return] dns mdns4' >> /etc/nsswitch.conf && \
    rm -rf /var/cache/apk/*

RUN wget https://sourceforge.net/projects/perfmon2/files/libpfm4/libpfm-4.11.0.tar.gz && \
  echo "112bced9a67d565ff0ce6c2bb90452516d1183e5  libpfm-4.11.0.tar.gz" | sha1sum -c  && \
  tar -xzf libpfm-4.11.0.tar.gz && \
  rm libpfm-4.11.0.tar.gz

RUN export DBG="-g -Wall" && \
  make -e -C libpfm-4.11.0 && \
  make install -C libpfm-4.11.0

RUN git clone -b v02.00.00.3871 https://github.com/intel/ipmctl/ && \
    cd ipmctl && \
    mkdir output && \
    cd output && \
    cmake -DRELEASE=ON -DCMAKE_INSTALL_PREFIX=/ -DCMAKE_INSTALL_LIBDIR=/usr/local/lib .. && \
    make -j all && \
    make install

RUN git clone https://github.com/google/cadvisor.git /go/src/github.com/google/cadvisor

#Checkout version if set
WORKDIR /go/gitea
RUN latestTag=$(git rev-list --tags --max-count=1) && \
    if [ -n "${latestTag}" ]; then git checkout "${latestTag}"; fi && \
    GO_FLAGS="-tags=libpfm,netgo,libipmctl" make clean-all build

FROM alpine:edge
LABEL maintainer="Hugo Ferreira"

RUN echo "http://dl-cdn.alpinelinux.org/alpine/edge/community/" >> /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing/" >> /etc/apk/repositories && \
    apk update && \
    apk upgrade --available && \
    apk --update add \
    bash libc6-compat device-mapper findutils zfs ndctl thin-provisioning-tools && \
    echo 'hosts: files mdns4_minimal [NOTFOUND=return] dns mdns4' >> /etc/nsswitch.conf && \
    sync && \
    rm -rf /tmp/* /var/tmp/* /var/cache/apk/* /var/cache/distfiles/*


# Grab cadvisor,libpfm4 and libipmctl from "build" container.
COPY --from=build-env /usr/local/lib/libpfm.so* /usr/local/lib/
COPY --from=build-env /usr/local/lib/libipmctl.so* /usr/local/lib/
COPY --from=build-env /go/src/github.com/google/cadvisor/cadvisor /usr/bin/cadvisor

EXPOSE 8080

ENV CADVISOR_HEALTHCHECK_URL=http://localhost:8080/healthz

HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget --quiet --tries=1 --spider $CADVISOR_HEALTHCHECK_URL || exit 1

ENTRYPOINT ["/usr/bin/cadvisor", "-logtostderr"]
