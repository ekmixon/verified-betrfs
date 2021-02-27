#!/bin/bash

# Copyright 2018-2021 VMware, Inc.
# SPDX-License-Identifier: MIT

#
# Run this script as root (sudo tools/prep-environment.sh) to install a recent
# version of .NET and a few other necessary tools.

set -e

function apt_based_install() {
    apt-get update
    apt-get install wget time make unzip graphviz apt-transport-https python3-pip
    pip3 install toposort
    # Derived from https://docs.microsoft.com/en-us/dotnet/core/install/linux-debian
    wget https://packages.microsoft.com/config/${ID}/${VERSION_ID}/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
    dpkg -i packages-microsoft-prod.deb
    rm packages-microsoft-prod.deb
    apt-get update
    apt-get install -y dotnet-sdk-5.0
}

# We welcome patches to add support for rpm-based distros...

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" == "debian" ]; then
        apt_based_install
    elif [ "$ID" == "ubuntu" ]; then
        apt_based_install
    fi
else
    # We welcome patches to identify distributions that don't have /etc/os-release...
    echo "Could not identify Linux distribution."
fi
