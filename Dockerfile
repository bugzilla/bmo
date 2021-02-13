FROM perl:5.32-slim AS builder

ENV DEBIAN_FRONTEND noninteractive
ENV LOG4PERL_CONFIG_FILE=log4perl-json.conf

RUN apt-get update
RUN apt-get install -y \
    apt-file \
    build-essential \
    cmake \
    curl \
    default-libmysqlclient-dev \
    git \
    libcairo-dev \
    libexpat-dev \
    libgd-dev \
    libssl-dev \
    openssl \
    zlib1g-dev

RUN cpanm --notest --quiet App::cpm Module::CPANfile Carton::Snapshot

# we run a loopback logging server on this TCP port.
ENV LOGGING_PORT=5880

WORKDIR /opt/bugzilla
COPY cpanfile cpanfile.snapshot /opt/bugzilla/
RUN cpm install


RUN apt-file update
RUN find local -name '*.so' -exec ldd {} \; \
    | egrep -v 'not.found|not.a.dynamic.executable' \
    | awk '$3 {print $3}' \
    | sort -u \
    | xargs -IFILE apt-file search -l FILE \
    | sort -u > PACKAGES

FROM perl:5.32-slim

WORKDIR /opt/bugzilla
COPY --from=builder /opt/bugzilla/PACKAGES /PACKAGES
RUN apt-get update \
    && apt-get install -y \
       curl \
       git \
       graphviz \
       libcap2-bin \
       rsync \
       $(cat /PACKAGES) \
    && rm -rf /var/cache/apt/* /var/lib/apt/lists/* /PACKAGES

COPY . /opt/bugzilla
COPY --from=builder /opt/bugzilla/local /opt/bugzilla/local
RUN perl checksetup.pl --no-database --default-localconfig --no-templates

VOLUME ["/opt/bugzilla/data", "/opt/bugzilla/graphs"]

ENTRYPOINT ["/opt/bugzilla/bugzilla.pl"]
