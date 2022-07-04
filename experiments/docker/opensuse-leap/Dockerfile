FROM opensuse/leap:15.0

RUN zypper install -y --no-recommends git && git clone https://invent.kde.org/sdk/kdesrc-build.git /opt/kdesrc-build && cd /opt/kdesrc-build

WORKDIR /opt/kdesrc-build

RUN ./kdesrc-build --initial-setup && ./kdesrc-build --metadata-only
RUN ./kdesrc-build --include-dependencies --stop-on-failure dolphin
