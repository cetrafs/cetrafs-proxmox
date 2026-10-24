#!/usr/bin/perl

# ui/cetrafs-ui-index: adds/removes the UI script tag in a copy of the PVE
# index template. Needs no PVE host.

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;

my $script = 'ui/cetrafs-ui-index';
my $dir = tempdir(CLEANUP => 1);
my $index = "$dir/index.html.tpl";

my $template = <<'EOF';
<!DOCTYPE html>
<html>
  <head>
    <script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>
    <script type="text/javascript" src="/pve2/ext6/locale/locale-[% lang %].js"></script>
  </head>
</html>
EOF

sub write_index {
    my ($content) = @_;
    open(my $fh, '>', $index) or die "$index: $!\n";
    print $fh $content;
    close($fh);
}

sub read_index {
    open(my $fh, '<', $index) or die "$index: $!\n";
    local $/;
    return <$fh>;
}

sub run_script {
    my ($action) = @_;
    local $ENV{CETRAFS_UI_INDEX} = $index;
    local $ENV{CETRAFS_UI_VERSION} = '1.2-3';
    return system('sh', $script, $action) >> 8;
}

my $tag = '<script type="text/javascript" src="/pve2/js/cetrafs-ui.js?ver=1.2-3"></script>';

write_index($template);
isnt(run_script('status'), 0, 'status: not applied');

is(run_script('apply'), 0, 'apply');
my $applied = read_index();
like($applied, qr/pvemanagerlib\.js[^\n]*\n[^\n]*\Q$tag\E/, 'tag right after pvemanagerlib.js');
is(run_script('status'), 0, 'status: applied');

is(run_script('apply'), 0, 'apply again');
is(read_index(), $applied, 'apply is idempotent');

is(run_script('revert'), 0, 'revert');
is(read_index(), $template, 'revert restores the template');
is(run_script('revert'), 0, 'revert when not applied');

# A failing stage before replace_index must not replace the template with
# short output: fake an awk that dies without printing anything.
{
    my $bin = "$dir/bin";
    mkdir($bin) or die "$bin: $!\n";
    open(my $fh, '>', "$bin/awk") or die "$bin/awk: $!\n";
    print $fh "#!/bin/sh\nexit 1\n";
    close($fh);
    chmod(0755, "$bin/awk") or die "$bin/awk: $!\n";

    write_index($template);
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    isnt(run_script('apply'), 0, 'apply fails when the pipeline produces nothing');
    is(read_index(), $template, 'template left unchanged');
    opendir(my $dh, $dir) or die "$dir: $!\n";
    is_deeply([grep { /\.cetrafs-ui\./ } readdir($dh)], [], 'no temp file left behind');
}

my $other = "<html><head></head></html>\n";
write_index($other);
is(run_script('apply'), 0, 'apply on an unknown template does not fail');
is(read_index(), $other, 'unknown template left alone');

unlink($index);
is(run_script('apply'), 0, 'apply without a template does not fail');

done_testing();
