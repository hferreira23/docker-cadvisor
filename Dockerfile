###################################
#Build stage
FROM golang:1.15-alpine AS build-env

ARG TARGETARCH
ARG GOPROXY
ENV GOARCH=$TARGETARCH
ENV GOPROXY ${GOPROXY:-direct}
ENV GO_TAGS netgo
ENV CGO_ENABLED 1

ADD env.sh /env.sh

RUN apk --no-cache add libc6-compat device-mapper findutils build-base linux-headers bash go git wget cmake pkgconfig ndctl-dev make python3 && \
    apk --no-cache add zfs || true && \
    apk --no-cache add thin-provisioning-tools --repository http://dl-3.alpinelinux.org/alpine/edge/main/ && \
    echo 'hosts: files mdns4_minimal [NOTFOUND=return] dns mdns4' >> /etc/nsswitch.conf && \
    rm -rf /var/cache/apk/*

RUN wget https://sourceforge.net/projects/perfmon2/files/libpfm4/libpfm-4.11.0.tar.gz && \
    echo "112bced9a67d565ff0ce6c2bb90452516d1183e5  libpfm-4.11.0.tar.gz" | sha1sum -c  && \
    tar -xzf libpfm-4.11.0.tar.gz && \
    rm libpfm-4.11.0.tar.gz

RUN export DBG="-g -Wall" && \
    make -e -C libpfm-4.11.0 || true && \
    make install -C libpfm-4.11.0 || true

RUN git clone -b v02.00.00.3871 https://github.com/intel/ipmctl/ && \
    cd ipmctl && \
    mkdir output && \
    cd output && \
    cmake -DRELEASE=ON -DCMAKE_INSTALL_PREFIX=/ -DCMAKE_INSTALL_LIBDIR=/usr/local/lib .. && \
    make -j all || true && \
    make install || true

RUN git clone https://github.com/google/cadvisor.git /go/src/github.com/google/cadvisor

WORKDIR /
RUN chmod +x /env.sh && \
    ./env.sh && \
    cd /go/src/github.com/google/cadvisor && \
    ./build/assets.sh && \
    GO_FLAGS="-tags=${GO_TAGS}" ./build/build.sh ${GOARCH}

FROM alpine:edge
LABEL maintainer="Hugo Ferreira"

ENV TZ=Europe/Lisbon

RUN echo "http://dl-cdn.alpinelinux.org/alpine/edge/community/" >> /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing/" >> /etc/apk/repositories && \
    apk update && \
    apk upgrade --available && \
    apk --update add \
    bash libc6-compat device-mapper findutils ndctl thin-provisioning-tools tzdata && \
    apk --no-cache add zfs || true && \
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
