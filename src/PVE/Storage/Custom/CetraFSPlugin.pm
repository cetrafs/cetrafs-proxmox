package PVE::Storage::Custom::CetraFSPlugin;

# Proxmox VE storage plugin for cetrafs, a clustered shared-disk filesystem.
#
# Every node mounts the same shared LUN (iSCSI / FC) with `mount -t cetrafs`
# and the volume is then used like a directory storage.
#
# The LUN is given either directly ('cetrafs-device') or, like LVM over iSCSI,
# as a LUN of a PVE 'iscsi' storage ('base'). PVE::Storage::activate_storage
# activates the base storage (iSCSI login) before ours. The storage is always
# shared: cetrafs coordinates the nodes through the disk itself (SCSI COMPARE
# AND WRITE), so no cluster-level locking is needed on our side.

use strict;
use warnings;

use Cwd ();

use PVE::INotify;
use PVE::ProcFSTools;
use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::Tools qw(run_command);

use base qw(PVE::Storage::Plugin);

# Highest storage plugin API version this plugin was tested against.
use constant TESTED_APIVER => 16;

# The storage is the same on all nodes; let PVE treat it as shared (migration
# without copying disks, HA, ...).
push @PVE::Storage::Plugin::SHARED_STORAGE, 'cetrafs'
    if !grep { $_ eq 'cetrafs' } @PVE::Storage::Plugin::SHARED_STORAGE;

sub api {
    my $apiver = PVE::Storage::APIVER;
    return $apiver < TESTED_APIVER ? $apiver : TESTED_APIVER;
}

sub type {
    return 'cetrafs';
}

sub plugindata {
    return {
        content => [
            {
                images => 1,
                rootdir => 1,
                vztmpl => 1,
                iso => 1,
                backup => 1,
                snippets => 1,
                import => 1,
                none => 1,
            },
            { images => 1 },
        ],
        format => [{ raw => 1, qcow2 => 1, vmdk => 1 }, 'raw'],
    };
}

# Property names are global across all storage plugins, so ours are prefixed.
# 'path', 'options' and 'base' are reused from the built-in plugins.
sub properties {
    return {
        'cetrafs-device' => {
            description => "Shared block device holding the cetrafs volume"
                . " (use a stable path, e.g. /dev/disk/by-id/...).",
            type => 'string',
            format => 'pve-storage-path',
        },
    };
}

sub options {
    return {
        path => { fixed => 1 },
        'cetrafs-device' => { fixed => 1, optional => 1 },
        base => { fixed => 1, optional => 1 },
        options => { optional => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        'content-dirs' => { optional => 1 },
        format => { optional => 1 },
        preallocation => { optional => 1 },
        mkdir => { optional => 1 },
        'create-base-path' => { optional => 1 },
        'create-subdirs' => { optional => 1 },
        bwlimit => { optional => 1 },
        'prune-backups' => { optional => 1 },
        'max-protected-backups' => { optional => 1 },
    };
}

sub check_config {
    my ($class, $sectionId, $config, $create, $skipSchemaCheck) = @_;

    if ($create) {
        $config->{path} = "/mnt/pve/$sectionId" if !$config->{path};

        die "exactly one of 'cetrafs-device' or 'base' is required\n"
            if !!$config->{'cetrafs-device'} == !!$config->{base};

        if (my $device = $config->{'cetrafs-device'}) {
            die "cetrafs-device '$device' is not a stable device path: kernel names like"
                . " /dev/sdX or /dev/dm-N can differ between nodes and boots - use"
                . " /dev/disk/by-id/... or /dev/mapper/<name>\n"
                if is_unstable_device_path($device);
        }
    }

    return $class->SUPER::check_config($sectionId, $config, $create, $skipSchemaCheck);
}

# Helpers

# Kernel-assigned names, numbered in discovery/activation order.
sub is_unstable_device_path {
    my ($device) = @_;

    return $device =~ m!^/dev/(?:[shv]d[a-z]+|xvd[a-z]+|dm-\d+|nvme\d+n\d+)(?:p?\d+)?$!;
}

sub cetrafs_device_path {
    my ($scfg) = @_;

    if (my $base = $scfg->{base}) {
        return PVE::Storage::path(PVE::Storage::config(), $base);
    }

    return $scfg->{'cetrafs-device'};
}

sub cetrafs_is_mounted {
    my ($scfg, $mountdata) = @_;

    my $path = Cwd::realpath($scfg->{path});
    return 0 if !defined($path);

    $mountdata //= PVE::ProcFSTools::parse_proc_mounts();

    return grep { $_->[1] eq $path && $_->[2] eq 'cetrafs' } @$mountdata;
}

sub cetrafs_mount {
    my ($scfg, $storeid) = @_;

    my $device = cetrafs_device_path($scfg);
    die "cetrafs device '$device' is not a block device\n" if !-b $device;

    # The module is not auto-loaded by 'mount -t cetrafs' (no fs alias), so
    # after boot nothing has loaded it yet.
    run_command(['/sbin/modprobe', 'cetrafs'], errmsg => 'unable to load cetrafs kernel module');

    # TODO: online migration needs the image open on two nodes at once
    # (cetrafs 'nofilelock' mount option) - decide whether to always mount
    # with it or to toggle it around the migration.
    my $cmd = ['/bin/mount', '-t', 'cetrafs'];
    push @$cmd, '-o', $scfg->{options} if $scfg->{options};
    push @$cmd, $device, $scfg->{path};

    run_command($cmd, errmsg => "mount error for storage '$storeid'");
}

# Storage implementation

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    if (my $base = $scfg->{base}) {
        my ($baseid) = PVE::Storage::parse_volume_id($base);

        my $basecfg = PVE::Storage::storage_config(PVE::Storage::config(), $baseid, 1);
        die "base storage ID '$baseid' does not exist\n" if !$basecfg;
        die "unsupported base type '$basecfg->{type}'\n" if $basecfg->{type} ne 'iscsi';
    }

    return undef;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} //= PVE::ProcFSTools::parse_proc_mounts();

    return undef if !cetrafs_is_mounted($scfg, $cache->{mountdata});

    return $class->SUPER::status($storeid, $scfg, $cache);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} //= PVE::ProcFSTools::parse_proc_mounts();

    if (!cetrafs_is_mounted($scfg, $cache->{mountdata})) {
        my $path = $scfg->{path};

        $class->config_aware_base_mkdir($scfg, $path);

        die "unable to activate storage '$storeid' - directory '$path' does not exist\n"
            if !-d $path;

        cetrafs_mount($scfg, $storeid);
        delete $cache->{mountdata};
    }

    $class->SUPER::activate_storage($storeid, $scfg, $cache);
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} //= PVE::ProcFSTools::parse_proc_mounts();

    if (cetrafs_is_mounted($scfg, $cache->{mountdata})) {
        run_command(['/bin/umount', $scfg->{path}], errmsg => 'umount error');
    }
}

# Runs on every node that activates the storage (pvestatd polls it), so this
# is where a node that cannot see the shared device gets reported.
sub check_connection {
    my ($class, $storeid, $scfg) = @_;

    my $device = cetrafs_device_path($scfg);
    return 1 if -b $device;

    my $node = PVE::INotify::nodename();
    die "device '$device' not found on node '$node' - the LUN is not attached to this node\n"
        if $scfg->{base};
    die "device '$device' not found on node '$node' - is multipathd running and configured"
        . " the same on every node?\n"
        if $device =~ m!^/dev/mapper/!;
    die "device '$device' not found on node '$node' - with 'cetrafs-device' every node must"
        . " already see the device (attach / log in to it on each node, or use 'base' with a"
        . " PVE iscsi storage)\n";
}

1;
