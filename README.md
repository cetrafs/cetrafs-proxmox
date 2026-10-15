# pve-storage-cetrafs

Proxmox VE storage plugin for [cetrafs](../cetrafs), the clustered shared-disk
filesystem. It adds a `cetrafs` storage type: every node mounts the same
shared LUN with `mount -t cetrafs` and PVE uses it as **shared** directory
storage (VM images, container volumes, ISOs, templates, backups).

## Layout

```
src/PVE/Storage/Custom/CetraFSPlugin.pm   the plugin (installed to /usr/share/perl5/PVE/Storage/Custom/)
t/                                        tests (run with `make test`, needs a PVE host / libpve-storage-perl)
debian/                                   packaging for pve-storage-cetrafs
```

PVE loads every module under `PVE/Storage/Custom/` at startup. The package
fires the `pve-api-updates` trigger so pve-manager restarts pvedaemon,
pveproxy, pvestatd and pvescheduler after install or upgrade.

## Build

```sh
apt install build-essential debhelper devscripts
make test
make deb          # -> dist/pve-storage-cetrafs_<version>_all.deb
```

## Usage

The cetrafs kernel module (`cetrafs-dkms`) must be installed on every node,
and the LUN formatted once with `mkfs.cetra`.

```sh
pvesm add cetrafs san1 --cetrafs-device /dev/disk/by-id/wwn-0x... --content images,rootdir
```

The mount point defaults to `/mnt/pve/<storeid>`. Extra mount options go in
`--options`.

Resulting `/etc/pve/storage.cfg` entry:

```
cetrafs: san1
	path /mnt/pve/san1
	cetrafs-device /dev/disk/by-id/wwn-0x...
	content images,rootdir
```
