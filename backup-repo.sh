#!/bin/bash

TARGET_DIR="$1"

vargit() {
    /usr/bin/git --git-dir="$TARGET_DIR/.git/" --work-tree="$TARGET_DIR" "$@"
}

gstatus=$(vargit status --porcelain)

if [ ${#gstatus} -ne 0 ]
then

    vargit add --all
    vargit commit -m "Automated snaptop: $gstatus"
    vargit pull --rebase
    vargit push

fi