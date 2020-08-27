#!/bin/bash

# Copyright (c) 2020 Intel Corporation.
# All rights reserved.
#
# SPDX-License-Identifier: Apache-2.0

set -eE

#---------      Global variable     -------------------
reboot_required=0
QEMU_REL="qemu-4.2.0"
CIV_WORK_DIR=$(pwd)
CIV_GOP_DIR=$CIV_WORK_DIR/GOP_PKG
CIV_VERTICAl_DIR=$CIV_WORK_DIR/vertical_patches/host

#---------      Functions    -------------------
function error() {
    local line=$1
    local cmd=$2
    echo "$BASH_SOURCE Failed at line($line): $cmd"
}

function ubu_changes_require(){
    echo "Please make sure your apt is working"
    echo "If you run the installation first time, reboot is required"
    read -p "QEMU version will be replaced (it could be recovered by 'apt purge ^qemu, apt install qemu'), do you want to continue? [Y/n]" res
    if [ x$res = xn ]; then
        return 1
    fi
    sudo apt install -y wget mtools ovmf dmidecode python3-usb python3-pyudev pulseaudio jq
}

function ubu_install_qemu_gvt(){
    sudo apt purge -y "^qemu"
    sudo apt autoremove -y
    sudo apt install -y git libfdt-dev libpixman-1-dev libssl-dev vim socat libsdl2-dev libspice-server-dev autoconf libtool xtightvncviewer tightvncserver x11vnc uuid-runtime uuid uml-utilities bridge-utils python-dev liblzma-dev libc6-dev libegl1-mesa-dev libepoxy-dev libdrm-dev libgbm-dev libaio-dev libusb-1.0-0-dev libgtk-3-dev bison libcap-dev libattr1-dev flex libvirglrenderer-dev build-essential gettext libegl-mesa0 libegl-dev libglvnd-dev libgl1-mesa-dev libgl1-mesa-dev libgles2-mesa-dev libegl1 gcc g++ pkg-config libpulse-dev libgl1-mesa-dri

    [ ! -f $CIV_WORK_DIR/$QEMU_REL.tar.xz ] && wget https://download.qemu.org/$QEMU_REL.tar.xz -P $CIV_WORK_DIR
    [ -d $CIV_WORK_DIR/$QEMU_REL ] && rm -rf $CIV_WORK_DIR/$QEMU_REL
    tar -xf $CIV_WORK_DIR/$QEMU_REL.tar.xz

    cd $CIV_WORK_DIR/$QEMU_REL/
    patch -p1 < $CIV_WORK_DIR/patches/qemu/Disable-EDID-auto-generation-in-QEMU.patch
    patch -p1 < $CIV_WORK_DIR/patches/qemu/0001-Revert-Revert-vfio-pci-quirks.c-Disable-stolen-memor.patch
    if [ -d $CIV_GOP_DIR ]; then
        for i in $CIV_GOP_DIR/qemu/*.patch; do patch -p1 < $i; done
    fi

    if [ -d $CIV_VERTICAl_DIR ]; then
	for i in $CIV_VERTICAl_DIR/qemu/*.patch; do
        echo "applying qemu patch $i";
        patch -p1 < $i; done
    fi

    ./configure --prefix=/usr \
        --enable-kvm \
        --disable-xen \
        --enable-libusb \
        --enable-debug-info \
        --enable-debug \
        --enable-sdl \
        --enable-vhost-net \
        --enable-spice \
        --disable-debug-tcg \
        --enable-opengl \
        --enable-gtk \
        --enable-virtfs \
        --target-list=x86_64-softmmu \
        --audio-drv-list=pa
    make -j24
    sudo make install
    cd -
}

function ubu_build_ovmf_gvt(){
    sudo apt install -y uuid-dev nasm acpidump iasl
    cd $CIV_WORK_DIR/$QEMU_REL/roms/edk2

    patch -p4 < $CIV_WORK_DIR/patches/ovmf/OvmfPkg-add-IgdAssgingmentDxe-for-qemu-4_2_0.patch
    if [ -d $CIV_GOP_DIR ]; then
        for i in $CIV_GOP_DIR/ovmf/*.patch; do patch -p1 < $i; done
        cp $CIV_GOP_DIR/ovmf/Vbt.bin OvmfPkg/Vbt/Vbt.bin
    fi

    if [ -d $CIV_VERTICAl_DIR ]; then
        for i in $CIV_VERTICAl_DIR/ovmf/*.patch; do
                echo "applying ovmf patch $i";
                patch -p1 < $i; done
    fi

    source ./edksetup.sh
    make -C BaseTools/
    build -b DEBUG -t GCC5 -a X64 -p OvmfPkg/OvmfPkgX64.dsc -D NETWORK_IP4_ENABLE -D NETWORK_ENABLE  -D SECURE_BOOT_ENABLE -DTPM2_ENABLE=TRUE
    cp Build/OvmfX64/DEBUG_GCC5/FV/OVMF.fd ../../../OVMF.fd

    if [ -d $CIV_GOP_DIR ]; then
        local gpu_device_id=$(cat /sys/bus/pci/devices/0000:00:02.0/device)
        ./BaseTools/Source/C/bin/EfiRom -f 0x8086 -i $gpu_device_id -e $CIV_GOP_DIR/IntelGopDriver.efi -o $CIV_GOP_DIR/GOP.rom
    fi

    cd -
}

function ubu_enable_host_gvt(){
    if [[ ! `cat /etc/default/grub` =~ "i915.enable_gvt=1 intel_iommu=on i915.force_probe=*" ]]; then
        read -p "The grub entry in '/etc/default/grub' will be updated for enabling GVT-g and GVT-d, do you want to continue? [Y/n]" res
        if [ x$res = xn ]; then
            exit 0
        fi
        sed -i "s/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"i915.enable_gvt=1 intel_iommu=on i915.force_probe=*/g" /etc/default/grub
        update-grub

        echo -e "\nkvmgt\nvfio-iommu-type1\nvfio-mdev\n" >> /etc/initramfs-tools/modules
        update-initramfs -u -k all

        reboot_required=1
    fi
}

function check_os() {
    local version=`cat /proc/version`

    if [[ ! $version =~ "Ubuntu" ]]; then
        echo "only Ubuntu is supported, exit!"
        return -1
    fi
}

function check_network(){
    wget --timeout=3 --tries=1 https://download.qemu.org/ -q -O /dev/null
    if [ $? -ne 0 ]; then
        echo "access https://download.qemu.org failed!"
        echo "please make sure network is working"
        return -1
    fi
}

function check_kernel_version() {
    local cur_ver=$(uname -r | sed "s/\([0-9.]*\).*/\1/")
    local req_ver="5.0.0"

    if [ "$(printf '%s\n' "$cur_ver" "$req_ver" | sort -V | head -n1)" != "$req_ver" ]; then
        echo "E: Detected Linux version: $cur_ver!"
        echo "E: Please upgrade kernel version newer than $req_ver!"
        return -1
    fi
}

function ask_reboot(){
    if [ $reboot_required -eq 1 ];then
        read -p "Reboot is required, do you want to reboot it NOW? [y/N]" res
        if [ x$res = xy ]; then
            reboot
        else
            echo "Please reboot system later to take effect"
        fi
    fi
}

function prepare_required_scripts(){
    chmod +x $CIV_WORK_DIR/scripts/*.sh
    cp -R $CIV_WORK_DIR/scripts/sof_audio/ $CIV_WORK_DIR/
    chmod +x $CIV_WORK_DIR/scripts/guest_pm_control
    chmod +x $CIV_WORK_DIR/scripts/findall.py
    chmod +x $CIV_WORK_DIR/scripts/thermsys
    chmod +x $CIV_WORK_DIR/scripts/batsys
}

function install_auto_start_service(){
    service_file=civ.service
    touch $service_file
    cat /dev/null > $service_file

    echo "[Unit]" > $service_file
    echo -e "Description=CiV Auto Start\n" >> $service_file

    echo "[Service]" >> $service_file
    echo -e "WorkingDirectory=$CIV_WORK_DIR\n" >> $service_file
    echo -e "ExecStart=/bin/bash -E $CIV_WORK_DIR/scripts/start_civ.sh\n" >> $service_file

    echo "[Install]" >> $service_file
    echo -e "WantedBy=multi-user.target\n" >> $service_file

    sudo mv $service_file /etc/systemd/system/
    sudo systemctl enable $civ_service
}

function ubu_thermal_conf() {
    #starting Intel Thermal Deamon, currently supporting CML/EHL only.
    sudo systemctl stop thermald.service
    sudo cp $CIV_WORK_DIR/scripts/intel-thermal-conf.xml /etc/thermald
    sudo cp $CIV_WORK_DIR/scripts/thermald.service  /lib/systemd/system
    sudo systemctl daemon-reload
    sudo systemctl start thermald.service
}

function set_host_ui() {
    if [[ $1 == "headless" ]]; then
        [[ $(systemctl get-default) == "multi-user.target" ]] && return 0
        sudo systemctl set-default multi-user.target
        reboot_required=1
    elif [[ $1 == "GUI" ]]; then
        [[ $(systemctl get-default) == "graphical.target" ]] && return 0
        sudo systemctl set-default graphical.target
        reboot_required=1
    else
        echo "$0: Unsupported mode: $1"
        return -1
    fi
}

function setup_sof() {
    $CIV_WORK_DIR/sof_audio/configure_sof.sh "install" $CIV_WORK_DIR
    $CIV_WORK_DIR/scripts/setup_audio_host.sh
}

function ubu_install_swtpm() {
    TPMS_VER=v0.7.3
    TPMS_LIB=libtpms-0.7.3
    SWTPM_VER=v0.3.3
    SWTPM=swtpm-0.3.3

    #install libtpms
    apt-get -y install automake autoconf gawk
    [ ! -f $TPMS_VER.tar.gz ] && wget https://github.com/stefanberger/libtpms/archive/$TPMS_VER.tar.gz -P $CIV_WORK_DIR
    [ -d $CIV_WORK_DIR/$TPMS_LIB ] && rm -rf  $CIV_WORK_DIR/$TPMS_LIB
    tar zxvf $CIV_WORK_DIR/$TPMS_VER.tar.gz
    cd $CIV_WORK_DIR/$TPMS_LIB
    ./autogen.sh --with-tpm2 --with-openssl --prefix=/usr
    make -j24
    make -j24 check
    make install
    cd -

    #install swtpm
    apt-get -y install net-tools libseccomp-dev libtasn1-6-dev libgnutls28-dev expect
    [ ! -f $SWTPM_VER.tar.gz ] && wget https://github.com/stefanberger/swtpm/archive/$SWTPM_VER.tar.gz -P $CIV_WORK_DIR
    [ -d $CIV_WORK_DIR/$SWTPM ] && rm -rf  $CIV_WORK_DIR/$SWTPM
    tar zxvf $CIV_WORK_DIR/$SWTPM_VER.tar.gz
    cd $CIV_WORK_DIR/$SWTPM
    ./autogen.sh --with-openssl --prefix=/usr
    make -j24
    make install
    cd -
}

function show_help() {
    printf "$(basename "$0") [-q] [-u] [--auto-start]\n"
    printf "Options:\n"
    printf "\t-h  show this help message\n"
    printf "\t-u  specify Host OS's UI, support \"headless\" and \"GUI\" eg. \"-u headless\" or \"-u GUI\"\n"
    printf "\t--auto-start auto start CiV guest when Host boot up.\n"
}

function parse_arg() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|-\?|--help)
                show_help
                exit
                ;;

            -u)
                set_host_ui $2 || return -1
                shift
                ;;

            --auto-start)
                install_auto_start_service || return -1
                ;;

            -?*)
                echo "Error: Invalid option $1"
                show_help
                return -1
                ;;
            *)
                echo "unknown option: $1"
                return -1
                ;;
        esac
        shift
    done
}


#-------------    main processes    -------------

trap 'error ${LINENO} "$BASH_COMMAND"' ERR

parse_arg "$@"

check_os
check_network
check_kernel_version

ubu_changes_require
ubu_install_qemu_gvt
ubu_build_ovmf_gvt
ubu_enable_host_gvt

prepare_required_scripts
ubu_thermal_conf
setup_sof
ubu_install_swtpm

ask_reboot

echo "Done: \"$(realpath $0) $@\""
