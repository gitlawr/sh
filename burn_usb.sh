diskutil list
diskutil unmountDisk /dev/diskx
dd if=/path/to/iso/image of=/dev/rdiskx bs=1m
diskutil eject /dev/diskx
