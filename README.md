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

## Usage: cetrafs over iSCSI

All nodes see the same iSCSI LUN. PVE's built-in `iscsi` storage logs every
node in to the target; the `cetrafs` storage references one of its LUNs as
`base` (the same pattern as LVM over iSCSI) and mounts it on each node. PVE
activates the iSCSI storage automatically before mounting.

**One iSCSI storage per target, one cetrafs storage per LUN.** The `iscsi`
storage logs in to the whole target, and every LUN the target exports shows
up as one of its volumes. A cetrafs volume lives on exactly one LUN, so each
LUN you want to use gets its own `cetrafs` storage (its own filesystem, mount
point and `mkfs.cetra`). A target with a single LUN is just the simplest
case; see "Several LUNs on one target" below for more.

The examples use portal `192.168.1.10`, target `iqn.2026-10.example:san`,
iSCSI storage `san-iscsi` and cetrafs storage `san1`. Replace them.

### 1. Install on every node

```sh
apt install cetrafs-dkms cetrafs-tools open-iscsi
dpkg -i pve-storage-cetrafs_<version>_all.deb
```

Install on **all** nodes before adding the storage: a node without the plugin
cannot use (or even parse) the `cetrafs` entry in `/etc/pve/storage.cfg`.

### 2. Add the iSCSI storage (once, from any node)

Discover the targets the portal offers:

```sh
pvesm scan iscsi 192.168.1.10
# iqn.2026-10.example:san        192.168.1.10:3260
# iqn.2026-10.example:other      192.168.1.10:3260
```

Pick the target that exports the LUN(s) for cetrafs and use its IQN as
`--target` below. (`iscsiadm -m discovery -t sendtargets -p 192.168.1.10`
gives the same list; a portal on a non-default port is `<ip>:<port>`.)

If the target only accepts listed initiators, allow every node's initiator
name (`cat /etc/iscsi/initiatorname.iscsi`) on the storage side first. PVE's
iSCSI storage has no CHAP option: if the target requires CHAP, set
`node.session.auth.*` in `/etc/iscsi/iscsid.conf` on every node.

```sh
pvesm add iscsi san-iscsi \
    --portal 192.168.1.10 \
    --target iqn.2026-10.example:san \
    --content none
```

`--content none` keeps the raw LUN from being offered as a VM disk. This
step can also be done in the web UI (Datacenter → Storage → Add → iSCSI,
untick "Use LUNs directly").

List the LUNs the target exports. There is one line per LUN:

```sh
pvesm list san-iscsi
# Volid                               Format  Type    Size
# san-iscsi:0.0.1.scsi-36001405abc... raw     images  ...
```

The volume id is `<iscsi storage>:<channel>.<id>.<lun>.<device id>`: the
third number is the LUN number and `scsi-3...` is the LUN's WWID. Always
refer to LUNs by volume id or WWID, never by `/dev/sdX`, whose names can
swap between boots.

To see which LUN is which (number, size, local device):

```sh
iscsiadm -m session -P 3 | grep -E 'Lun:|Attached scsi disk'
#   scsi8 Channel 00 Id 0 Lun: 1
#       Attached scsi disk sdd    State: running
lsblk -o NAME,SIZE,WWN /dev/sdd
ls -l /dev/disk/by-id/scsi-36001405abc...    # -> ../../sdd
```

Two devices with **different** WWIDs are two LUNs. The **same** WWID on two
devices (usually through two portals) is one LUN seen over two paths: that
is multipath, see "Without the iSCSI storage" below.

Steps 3 to 5 are per LUN: repeat them for each LUN you want to use.

### 3. Check the LUN supports clustering (once)

cetrafs needs atomic SCSI COMPARE AND WRITE to be shared by several nodes:

```sh
DEV=/dev/disk/by-id/scsi-36001405abc...
modprobe cetrafs caw_probe=$DEV
dmesg | tail          # need: max_caw_blocks=N with N >= 1
```

`max_caw_blocks=0` means the LUN can only ever be mounted by one node.

### 4. Format the LUN (once, from ONE node)

```sh
mkfs.cetra $DEV
```

This destroys whatever is on the LUN. Do it before adding the storage, with
the LUN mounted nowhere (mkfs refuses a volume a live peer has mounted). See
`docs/OPERATIONS.md` in cetrafs for the `mkfs.cetra` options.

### 5. Add the cetrafs storage (once, from any node)

```sh
pvesm add cetrafs san1 \
    --base san-iscsi:0.0.1.scsi-36001405abc... \
    --path /mnt/pve/san1 \
    --options nofilelock \
    --content images,rootdir,iso,vztmpl,backup
```

- `--base` — the LUN volume id from step 2.
- `--path` — the mount point, the same on every node. Optional (defaults to
  `/mnt/pve/<storeid>`) and created if missing. It cannot be changed later
  without removing and re-adding the storage.
- `--options` — mount options passed to `mount -t cetrafs -o ...`.
  `nofilelock` is required for **live** migration (otherwise the target's
  open fails with `Text file busy`); leave it out if you only migrate
  offline. See "The `nofilelock` option" in cetrafs `docs/OPERATIONS.md`.
- `--nodes` — optional, restrict the storage to some nodes.

The storage is always marked shared, so migration does not copy its disks.
Each node mounts it automatically: pvestatd activates every enabled storage
when it polls (about every 10 s), and any guest start does too.

Resulting `/etc/pve/storage.cfg`:

```
iscsi: san-iscsi
	portal 192.168.1.10
	target iqn.2026-10.example:san
	content none

cetrafs: san1
	path /mnt/pve/san1
	base san-iscsi:0.0.1.scsi-36001405abc...
	content images,rootdir,iso,vztmpl,backup
	options nofilelock
```

### Several LUNs on one target

Example: a target exporting LUN 1 and LUN 2.

```sh
pvesm list san-iscsi
# san-iscsi:0.0.1.scsi-36001405000000000000000000000a001   raw  images  ...
# san-iscsi:0.0.2.scsi-36001405000000000000000000000a002   raw  images  ...
```

Format each LUN you will use (step 4), then add one cetrafs storage per LUN,
each with its own mount point:

```sh
pvesm add cetrafs san1 \
    --base san-iscsi:0.0.1.scsi-36001405000000000000000000000a001 \
    --path /mnt/pve/san1 --options nofilelock --content images,rootdir

pvesm add cetrafs san2 \
    --base san-iscsi:0.0.2.scsi-36001405000000000000000000000a002 \
    --path /mnt/pve/san2 --options nofilelock --content images,rootdir
```

```
iscsi: san-iscsi
	portal 192.168.1.10
	target iqn.2026-10.example:san
	content none

cetrafs: san1
	path /mnt/pve/san1
	base san-iscsi:0.0.1.scsi-36001405000000000000000000000a001
	content images,rootdir
	options nofilelock

cetrafs: san2
	path /mnt/pve/san2
	base san-iscsi:0.0.2.scsi-36001405000000000000000000000a002
	content images,rootdir
	options nofilelock
```

- The two storages are independent filesystems: separate free space,
  separate mounts, and disabling or removing one does not affect the other.
  One cetrafs storage cannot span several LUNs.
- They share the one iSCSI storage and session; activating the second finds
  the target already logged in.
- A LUN you do not add as a cetrafs storage is left alone. With
  `--content none` on the iSCSI storage PVE never offers it as a VM disk.
  Do not use it for anything else that would write to it from several nodes.
- Each storage may use different `--options`; `nofilelock` is set per
  cetrafs volume.

### 6. Verify (on each node)

```sh
pvesm status --storage san1        # active
findmnt /mnt/pve/san1              # FSTYPE cetrafs, SOURCE the iSCSI LUN
iscsiadm -m session                # logged in to the target
```

The storage is mounted again automatically after a reboot: pvestatd
activates it at startup (iSCSI login, `modprobe cetrafs`, mount), before
guest autostart runs. No `/etc/fstab` entry is needed, and there must not be
one.

If it is not active, `journalctl -u pvestatd -u pvedaemon` shows the mount
error.

### Without the iSCSI storage

If the LUN is already attached to every node some other way (FC, iSCSI set
up by hand, multipath), point at the device directly instead of `--base`:

```sh
pvesm add cetrafs san1 --cetrafs-device /dev/mapper/36001405abc... --path /mnt/pve/san1
```

Use a path that is the same on every node (`/dev/disk/by-id/...` or the
multipath `/dev/mapper/<wwid>`), never `/dev/sdX`. Exactly one of
`--cetrafs-device` and `--base` must be set. With multipath prefer this form:
`--base` resolves to the LUN's `/dev/disk/by-id/scsi-*` link, which is not
guaranteed to be the multipath device.

### Removing

Stop or move the guests using it first. PVE neither unmounts nor logs out
when a storage is disabled or removed, so do it by hand.

Remove one cetrafs storage (other LUNs on the same target keep working):

```sh
pvesm set san1 --disable 1          # stop PVE re-mounting it
umount /mnt/pve/san1                # on every node
pvesm remove san1
```

Once **no** cetrafs storage uses the target any more, remove the iSCSI
storage and log out:

```sh
pvesm remove san-iscsi
iscsiadm -m node -T iqn.2026-10.example:san --logout     # on every node
```

Removing the storage does not touch the data on the LUN.
