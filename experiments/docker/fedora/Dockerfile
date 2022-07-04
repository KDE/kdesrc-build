FROM fedora:29

RUN apt-get update --quiet -qq && apt-get --quiet -qq install perl-modules git cmake g++ libio-socket-ssl-perl libyaml-perl

RUN git clone https://invent.kde.org/sdk/kdesrc-build.git /tmp/kdesrc-build

RUN cd /tmp/kdesrc-build && prove -I modules
