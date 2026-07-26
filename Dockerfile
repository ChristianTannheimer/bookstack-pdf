# syntax=docker/dockerfile:1
#
# EBT BookStack mit gebrandetem PDF-Export (Deckblatt, Inhaltsverzeichnis, Fusszeile)
# Basis: linuxserver.io BookStack (Alpine) + WeasyPrint + NETWAYS/bookstack-to-pdf
#
# Build:
#   docker build --build-arg B2PDF_REF=<commit-sha> -t ghcr.io/christiantannheimer/bookstack-pdf:latest .

ARG BOOKSTACK_VERSION=latest
FROM lscr.io/linuxserver/bookstack:${BOOKSTACK_VERSION}

# Auf einen konkreten Commit pinnen. Das Projekt hat keine Releases und wenige
# Commits - "main" kann sich jederzeit brechend aendern.
# Aktuellen SHA holen:  git ls-remote https://github.com/NETWAYS/bookstack-to-pdf main
ARG B2PDF_REF=main

RUN apk add --no-cache \
        python3 \
        pango \
        harfbuzz \
        fontconfig \
        font-dejavu \
        font-liberation \
        libffi \
        git \
    && apk add --no-cache --virtual .build-deps \
        build-base \
        python3-dev \
        libffi-dev \
    && git clone https://github.com/NETWAYS/bookstack-to-pdf.git /opt/bookstack-to-pdf \
    && git -C /opt/bookstack-to-pdf checkout "${B2PDF_REF}" \
    && python3 -m venv /opt/bookstack-to-pdf/.venv \
    && /opt/bookstack-to-pdf/.venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/bookstack-to-pdf/.venv/bin/pip install --no-cache-dir /opt/bookstack-to-pdf \
    && rm -rf /opt/bookstack-to-pdf/.git \
    && apk del .build-deps git \
    && chmod -R o+rX /opt/bookstack-to-pdf \
    && fc-cache -f

# Smoke-Test schon zur Build-Zeit: bricht der Build, merkst du es hier und
# nicht erst, wenn ein Kunde sein Handbuch nicht bekommt.
RUN /opt/bookstack-to-pdf/.venv/bin/bookstack-to-pdf --help > /dev/null

LABEL org.opencontainers.image.source="https://github.com/christiantannheimer/bookstack-pdf" \
      org.opencontainers.image.description="BookStack mit WeasyPrint-PDF-Renderer fuer EBT-Kundenhandbuecher"
