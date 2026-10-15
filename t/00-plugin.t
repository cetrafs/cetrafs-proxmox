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

$cfg = { type => 'cetrafs', 'cetrafs-device' => '/dev/sdb', base => 'san:0.0.0.scsi-1' };
ok(!eval { $plugin->check_config('store4', $cfg, 1, 1); 1 }, 'not both device and base');

done_testing();
