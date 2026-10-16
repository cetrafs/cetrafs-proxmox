#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use PVE::Storage;
use PVE::Storage::Custom::CetraFSPlugin;

my $plugin = 'PVE::Storage::Custom::CetraFSPlugin';

# Not installed under /usr/share/perl5/PVE/Storage/Custom, so PVE::Storage did
# not pick it up: register it by hand and rebuild the section config schema.
$plugin->register() if !grep { $_ eq 'cetrafs' } PVE::Storage::Plugin->lookup_types()->@*;
PVE::Storage::Plugin->init();

isa_ok($plugin, 'PVE::Storage::Plugin');
is($plugin->type(), 'cetrafs', 'storage type');

my $api = $plugin->api();
cmp_ok($api, '<=', PVE::Storage::APIVER, 'API version not newer than PVE');
cmp_ok($api, '>=', PVE::Storage::APIVER - PVE::Storage::APIAGE, 'API version not too old');

ok((grep { $_ eq 'cetrafs' } @PVE::Storage::Plugin::SHARED_STORAGE), 'registered as shared');

my $cfg = { type => 'cetrafs', 'cetrafs-device' => '/dev/disk/by-id/wwn-0x1' };
$plugin->check_config('store1', $cfg, 1, 1);
is($cfg->{path}, '/mnt/pve/store1', 'default mount path');

$cfg = { type => 'cetrafs', base => 'san:0.0.0.scsi-36001405abcdef' };
ok(eval { $plugin->check_config('store2', $cfg, 1, 1); 1 }, 'base instead of device');

$cfg = { type => 'cetrafs' };
ok(!eval { $plugin->check_config('store3', $cfg, 1, 1); 1 }, 'device or base required');

$cfg = { type => 'cetrafs', 'cetrafs-device' => '/dev/disk/by-id/wwn-0x1', base => 'san:0.0.0.scsi-1' };
ok(!eval { $plugin->check_config('store4', $cfg, 1, 1); 1 }, 'not both device and base');

for my $dev (qw(/dev/sdb /dev/sdb1 /dev/dm-3 /dev/vda /dev/nvme0n1 /dev/nvme0n1p2)) {
    $cfg = { type => 'cetrafs', 'cetrafs-device' => $dev };
    ok(!eval { $plugin->check_config('store5', $cfg, 1, 1); 1 }, "unstable path $dev refused");
}

for my $dev (qw(/dev/disk/by-id/wwn-0x1 /dev/mapper/mpatha /dev/mapper/36001405000000000000000000000b001 /dev/disk/by-id/dm-name-foo)) {
    $cfg = { type => 'cetrafs', 'cetrafs-device' => $dev };
    ok(eval { $plugin->check_config('store6', $cfg, 1, 1); 1 }, "stable path $dev accepted");
}

is(PVE::Storage::Custom::CetraFSPlugin::cetrafs_mount_options({}), 'nofilelock',
    'nofilelock by default');
is(PVE::Storage::Custom::CetraFSPlugin::cetrafs_mount_options({ options => 'noatime' }),
    'noatime,nofilelock', 'nofilelock added to user options');
is(PVE::Storage::Custom::CetraFSPlugin::cetrafs_mount_options({ options => 'nofilelock,noatime' }),
    'nofilelock,noatime', 'nofilelock not duplicated');

done_testing();
