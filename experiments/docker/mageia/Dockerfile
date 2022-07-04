FROM mageia:latest

RUN dnf -y install git && git clone https://invent.kde.org/sdk/kdesrc-build.git /tmp/kdesrc-build

WORKDIR /tmp/kdesrc-build

RUN ./kdesrc-build --initial-setup && ./kdesrc-build --metadata-only
