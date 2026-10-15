package PVE::Storage::Custom::CetraFSPlugin;

# Proxmox VE storage plugin for cetrafs, a clustered shared-disk filesystem.
#
# Every node mounts the same shared LUN (iSCSI / FC) with `mount -t cetrafs`
# and the volume is then used like a directory storage. The storage is always
# shared: cetrafs coordinates the nodes through the disk itself (SCSI COMPARE
# AND WRITE), so no cluster-level locking is needed on our side.

use strict;
use warnings;

use Cwd ();

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
# 'path' and 'options' are reused from the built-in plugins.
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
        'cetrafs-device' => { fixed => 1 },
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

    $config->{path} = "/mnt/pve/$sectionId" if $create && !$config->{path};

    return $class->SUPER::check_config($sectionId, $config, $create, $skipSchemaCheck);
}

# Helpers

sub cetrafs_is_mounted {
    my ($scfg, $mountdata) = @_;

    my $path = Cwd::realpath($scfg->{path});
    return 0 if !defined($path);

    $mountdata //= PVE::ProcFSTools::parse_proc_mounts();

    return grep { $_->[1] eq $path && $_->[2] eq 'cetrafs' } @$mountdata;
}

sub cetrafs_mount {
    my ($scfg, $storeid) = @_;

    my $device = $scfg->{'cetrafs-device'};
    die "cetrafs device '$device' is not a block device\n" if !-b $device;

    # TODO: online migration needs the image open on two nodes at once
    # (cetrafs 'nofilelock' mount option) - decide whether to always mount
    # with it or to toggle it around the migration.
    my $cmd = ['/bin/mount', '-t', 'cetrafs'];
    push @$cmd, '-o', $scfg->{options} if $scfg->{options};
    push @$cmd, $device, $scfg->{path};

    run_command($cmd, errmsg => "mount error for storage '$storeid'");
}

# Storage implementation

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

sub check_connection {
    my ($class, $storeid, $scfg) = @_;

    return -b $scfg->{'cetrafs-device'} ? 1 : 0;
}

1;
