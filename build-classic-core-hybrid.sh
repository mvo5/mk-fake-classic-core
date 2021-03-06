#!/bin/sh

set -e

get_assets() {
    CACHE="$1"
    
    if [ -d "$CACHE" ]; then
        echo "Using exiting cache dir $CACHE"
        return
    fi
    
    mkdir -p "$CACHE"
    # get the snaps
    for snap in pc-kernel pc; do
        snap download --channel=20 --basename="${snap}" --target-directory="$CACHE" "${snap}"
        unsquashfs -n -d "$CACHE"/snap-"$snap" "$CACHE"/"$snap".snap
    done
    
    # get the ubuntu classic base
    (cd "$CACHE" && wget -c http://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.1-base-amd64.tar.gz)
}

cleanup() {
    IMG="$(readlink -f "$1")"
    MNT="$(readlink -f "$2")"

    sleep 1
    sudo umount "$MNT"/* || true
    sleep 1
    sudo kpartx -d "$IMG" || true
}

create_image() {
    IMG="$(readlink -f "$1")"

    rm -f "$IMG"
    truncate --size=6G "$IMG"
    echo "Creating partition on $IMG"
    cat <<EOF | sfdisk -q "$IMG"
label: gpt
device: boot.img
unit: sectors
first-lba: 34
last-lba: 12453854
sector-size: 512

boot.img1 : start=        2048, size=        2048, type=21686148-6449-6E6F-744E-656564454649, uuid=ECD24EAE-A687-4177-9223-6DDB4FCFF842, name="BIOS Boot"
##### no ubuntu-seed on the initial version but we need a EFI system
boot.img2 : start=        4096, size=     202752, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=21A0079F-3E45-4669-8FF2-B3917819279F, name="EFI System partition"
boot.img3 : start=     2461696, size=     1536000, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=338DD9E7-CFE1-524A-A8B6-7D87DA8A4B34, name="ubuntu-boot"
boot.img4 : start=     3997696, size=       32768, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=1144DFB5-DFC2-0745-A1F2-AD311FEBE0DB, name="ubuntu-save"
boot.img5 : start=     4030464, size=     8423391, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=B84565A3-E9F8-8A40-AB04-810A4B891F8C, name="ubuntu-data"
EOF
}

populate_image() {
    IMG="$(readlink -f "$1")"
    CACHE="$(readlink -f "$2")"
    MNT="$(readlink -f "$3")"

    mkdir -p "$MNT"
    sudo kpartx -av "$IMG"
    
    loop=$(sudo kpartx -l "$IMG" |tr -d " " | cut -f1 -d:|sed 's/..$//'|head -1)
    loop_esp="${loop}"p2
    loop_boot="${loop}"p3
    loop_save="${loop}"p4
    loop_data="${loop}"p5
    # XXX: on a real UC device this the ESP is "ubuntu-seed"
    sudo mkfs.vfat /dev/mapper/"$loop_esp"
    sudo mkfs.ext4 -L ubuntu-boot -q /dev/mapper/"$loop_boot"
    sudo mkfs.ext4 -L ubuntu-save -q /dev/mapper/"$loop_save"
    sudo mkfs.ext4 -L ubuntu-data -q /dev/mapper/"$loop_data"
    for name in esp ubuntu-boot ubuntu-save ubuntu-data; do 
        mkdir -p "$MNT"/"$name"
    done
    sudo mount /dev/mapper/"$loop_esp" "$MNT"/esp
    sudo mount /dev/mapper/"$loop_boot" "$MNT"/ubuntu-boot
    sudo mount /dev/mapper/"$loop_save" "$MNT"/ubuntu-save
    sudo mount /dev/mapper/"$loop_data" "$MNT"/ubuntu-data
    
    # install things into the image
    (cd "$MNT"/ubuntu-data && sudo tar xf "$CACHE"/ubuntu-base-20.04.1-base-amd64.tar.gz)

    # ESP partition just chainloads into ubuntu-boot
    # XXX: do we want this given that we don't have recovery systems?
    sudo mkdir -p "$MNT"/esp/EFI/boot
    sudo cp "$CACHE"/snap-pc/grubx64.efi "$MNT"/esp/EFI/boot
    sudo cp "$CACHE"/snap-pc/shim.efi.signed "$MNT"/esp/EFI/boot/bootx64.efi
    cat > "$CACHE"/esp-grub.cfg <<'EOF'
set default=0
set timeout=3

search --no-floppy --set=boot_fs --label ubuntu-boot
menuentry "Continue to run mode" --hotkey=n --id=run {
    chainloader ($boot_fs)/EFI/boot/grubx64.efi
}
EOF
    sudo mkdir -p "$MNT"/esp/EFI/ubuntu
    sudo cp "$CACHE"/esp-grub.cfg "$MNT"/esp/EFI/ubuntu/grub.cfg
    
    # ubuntu-boot
    sudo mkdir -p "$MNT"/ubuntu-boot/EFI/boot
    sudo cp -a "$CACHE"/snap-pc/grubx64.efi "$MNT"/ubuntu-boot/EFI/boot
    sudo cp -a "$CACHE"/snap-pc/shim.efi.signed "$MNT"/ubuntu-boot/EFI/boot/bootx64.efi

    sudo mkdir -p "$MNT"/ubuntu-boot/EFI/ubuntu
    cat > "$CACHE"/grub.cfg <<'EOF'
set default=0   
set timeout=3

# load only kernel_status and kernel command line variables set by snapd from
# the bootenv
load_env --file /EFI/ubuntu/grubenv kernel_status snapd_extra_cmdline_args snapd_full_cmdline_args

set snapd_static_cmdline_args='console=ttyS0 console=tty1 panic=-1'
set cmdline_args="$snapd_static_cmdline_args $snapd_extra_cmdline_args"
if [ -n "$snapd_full_cmdline_args" ]; then
    set cmdline_args="$snapd_full_cmdline_args"
fi

set kernel=kernel.efi

if [ "$kernel_status" = "try" ]; then
    # a new kernel got installed
    set kernel_status="trying"
    save_env kernel_status

    # use try-kernel.efi
    set kernel=try-kernel.efi
elif [ "$kernel_status" = "trying" ]; then
    # nothing cleared the "trying snap" so the boot failed
    # we clear the mode and boot normally
    set kernel_status=""
    save_env kernel_status
elif [ -n "$kernel_status" ]; then
    # ERROR invalid kernel_status state, reset to empty
    echo "invalid kernel_status!!!"
    echo "resetting to empty"
    set kernel_status=""
    save_env kernel_status
fi

if [ -e $prefix/$kernel ]; then
menuentry "Run Ubuntu Core 20" {
    # use $prefix because the symlink manipulation at runtime for kernel snap
    # upgrades, etc. should only need the /boot/grub/ directory, not the
    # /EFI/ubuntu/ directory
    chainloader $prefix/$kernel snapd_recovery_mode=run $cmdline_args
}
else
    # nothing to boot :-/
    echo "missing kernel at $prefix/$kernel!"
fi
EOF
    sudo cp -a "$CACHE"/grub.cfg "$MNT"/ubuntu-boot/EFI/ubuntu/
    cat > "$CACHE"/grubenv <<EOF
# GRUB Environment Block
#######################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################################
EOF
    sudo cp -a "$CACHE"/grubenv "$MNT"/ubuntu-boot/EFI/ubuntu/grubenv
    
    # kernel
    # XXX: setup pc-kernel_$rev/kernel.efi and a symlink instead
    sudo cp -a "$CACHE"/snap-pc-kernel/kernel.efi "$MNT"/ubuntu-boot/EFI/ubuntu/
    
    # cleanup
    sync
    sudo umount "$MNT"/ubuntu-*
}

show_how_to_run_qemu() {
    IMG="$1"

    echo "Image ready, run as"
    echo kvm -m 1500 -snapshot \
         -netdev user,id=net.0,hostfwd=tcp::10022-:22 \
        -device rtl8139,netdev=net.0 \
        -bios /usr/share/OVMF/OVMF_CODE.fd \
        -drive file="$1",if=virtio \
        -serial stdio

    echo "grub will chainload from ESP to ubuntu-boot"
    echo "there press ESC and add 'dangerous rd.systemd.debug-shell=1' after kernel.efi"
}

main() {
    trap "cleanup ./boot.img ./mnt" EXIT INT 

    get_assets ./cache
    create_image ./boot.img
    populate_image ./boot.img ./cache ./mnt

    show_how_to_run_qemu ./boot.img
    # XXX: show how to mount/chroot into the dir to test seeding
}

main

