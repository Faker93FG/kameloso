#!/bin/bash

install_deps() {
    sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list \
        -O /etc/apt/sources.list.d/d-apt.list
    sudo apt update

    # fingerprint 0xEBCF975E5BA24D5E
    sudo apt-get -y --allow-unauthenticated install --reinstall d-apt-keyring
    sudo apt update
    sudo apt install dmd-compiler dub

    sudo apt install ldc
}

build() {
    dub test --compiler="$1" --build-mode=singleFile
    dub test --compiler="$1" --build-mode=singleFile -c vanilla
    dub test --compiler="$1" --build-mode=singleFile -c colours+web

    #dub build --compiler="$1" --build-mode=singleFile -b plain
    dub build --compiler="$1" --build-mode=singleFile -b plain -c vanilla
    dub build --compiler="$1" --build-mode=singleFile -b plain -c colours+web
}

# execution start

case "$1" in
    install-deps)
        install_deps;
        ;;
    build)
        build dmd;
        #build ldc2;  # doesn't support single build mode
        ;;
    *)
        echo "Unknown command: $1";
        exit 1;
        ;;
esac

exit 0
