#!/bin/bash

set -uexo pipefail

install_deps() {
    sudo apt update
    sudo apt install -y apt-transport-https

    sudo wget https://netcologne.dl.sourceforge.net/project/d-apt/files/d-apt.list \
        -O /etc/apt/sources.list.d/d-apt.list
    sudo apt update --allow-insecure-repositories

    # fingerprint 0xEBCF975E5BA24D5E
    sudo apt install -y --allow-unauthenticated --reinstall d-apt-keyring
    sudo apt update
    sudo apt install dmd-compiler dub
    #sudo apt install ldc
}

build() {
    local A S

    A="--compiler=$1"
    S="--build-mode=singleFile"

    mkdir -p artifacts

    ## test
    time dub test $A $S
    A="$A --nodeps --force"
    #time dub test $A $S -c pluginless
    #time dub test $A $S -c colours
    time dub test $A $S -c vanilla


    ## debug
    time dub build $A $S -b debug -c full
    mv kameloso artifacts/kameloso

    time dub build $A $S -b debug -c twitch
    mv kameloso artifacts/kameloso-twitch

    #time dub build $A $S -b debug -c pluginless
    #mv kameloso artifacts/kameloso-pluginless

    time dub build $A $S -b debug -c colours
    mv kameloso artifacts/kameloso-colours

    time dub build $A $S -b debug -c vanilla
    mv kameloso artifacts/kameloso-vanilla


    ## plain
    time dub build $A $S -b plain -c full || true
    mv kameloso artifacts/kameloso-plain || \
        touch artifacts/kameloso-plain.failed

    time dub build $A $S -b plain -c twitch || true
    mv kameloso artifacts/kameloso-plain-twitch || \
        touch artifacts/kameloso-plain-twitch.failed

    #time dub build $A $S -b plain -c pluginless || true
    #mv kameloso artifacts/kameloso-plain-pluginless || \
        #touch artifacts/kameloso-plain-pluginless.failed

    time dub build $A $S -b plain -c colours || true
    mv kameloso artifacts/kameloso-plain-colours || \
        touch artifacts/kameloso-plain-colours.failed

    time dub build $A $S -b plain -c vanilla || true
    mv kameloso artifacts/kameloso-plain-vanilla || \
        touch artifacts/kameloso-plain-vanilla.failed


    ## release
    time dub build $A $S -b release -c full || true
    mv kameloso artifacts/kameloso-release || \
        touch artifacts/kameloso-release.failed

    time dub build $A $S -b release -c twitch || true
    mv kameloso artifacts/kameloso-release-twitch || \
        touch artifacts/kameloso-release-twitch.failed

    #time dub build $A $S -b release -c pluginless || true
    #mv kameloso artifacts/kameloso-release-pluginless || \
        #touch artifacts/kameloso-release-pluginless.failed

    time dub build $A $S -b release -c colours || true
    mv kameloso artifacts/kameloso-release-colours || \
        touch artifacts/kameloso-release-colours.failed

    time dub build $A $S -b release -c vanilla || true
    mv kameloso artifacts/kameloso-release-vanilla || \
        touch artifacts/kameloso-release-vanilla.failed
}

# execution start

case "$1" in
    install-deps)
        install_deps;
        ;;
    build)
        time build dmd;
        #build ldc2;  # 0.14.0; too old
        ;;
    *)
        echo "Unknown command: $1";
        exit 1;
        ;;
esac

exit 0
