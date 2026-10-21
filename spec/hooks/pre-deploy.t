#!/usr/bin/env perl
# Proves that the pre-deploy hook checks the merged manifest of a resolute
# deploy, which is the last place an override of the stemcells or of the bpm
# release can show up.  It also proves the noble bpm guard, the check that
# the API certificate names every node address, and the refusal to change
# the node count.
#
# Each case writes a small manifest, points GENESIS_MANIFEST_FILE at it, and
# runs the hook's resolute check.  spruce converts the manifest, as it does
# in a real deploy.  Run it with `prove spec/hooks` or
# `perl spec/hooks/pre-deploy.t`.

use v5.20;
use warnings;

use Cwd qw/abs_path/;
use File::Basename qw/dirname/;
use File::Temp qw/tempdir/;
use Test::More;

BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

chomp(my $spruce = `command -v spruce`);
plan skip_all => 'spruce is not installed' unless $spruce;

my $hooks = abs_path(dirname(__FILE__).'/../../hooks');
my $work  = tempdir('rustfs-predeploy-test-XXXXXX', TMPDIR => 1, CLEANUP => 1);
require "$hooks/pre-deploy.pm";

# check runs the resolute check on a manifest and returns whether it passed
# and what it printed.
sub check {
	my ($manifest) = @_;
	open(my $fh, '>', "$work/manifest.yml") or die;
	print {$fh} $manifest;
	close($fh);
	local $ENV{GENESIS_MANIFEST_FILE} = "$work/manifest.yml";
	my $hook = bless {label => 'pre-deploy'}, 'Genesis::Hook::PreDeploy::RustFS';
	my $ok = eval { $hook->_check_resolute; 1 };
	return ($ok, $@ // '');
}

my $resolute = "stemcells:\n- alias: default\n  os: ubuntu-resolute\n  version: \"0.184\"\n";
my $noble    = "stemcells:\n- alias: default\n  os: ubuntu-noble\n  version: latest\n";
sub bpm { "releases:\n- name: rustfs\n  version: 0.2.0+dev.1\n- name: bpm\n  version: $_[0]\n" }

my ($ok, $error);

($ok, $error) = check($resolute . bpm('1.4.41'));
ok($ok, 'resolute stemcells with bpm 1.4.41 pass') or diag($error);

($ok, $error) = check($resolute . bpm('1.5.0'));
ok($ok, 'a newer bpm passes') or diag($error);

($ok, $error) = check($noble . bpm('1.4.41'));
ok(!$ok, 'a noble stemcell is refused');
like($error, qr/ubuntu-noble/, 'the refusal names the stemcell os');

($ok, $error) = check($resolute . "- alias: extra\n  os: ubuntu-jammy\n  version: latest\n" . bpm('1.4.41'));
ok(!$ok, 'a second stemcell on another os is refused');
like($error, qr/extra/, 'the refusal names the stemcell alias');

($ok, $error) = check($resolute . bpm('1.4.22'));
ok(!$ok, 'bpm 1.4.22 is refused');
like($error, qr/1\.4\.22/, 'the refusal names the bpm version');

($ok, $error) = check($resolute . bpm('latest'));
ok(!$ok, 'bpm latest is refused');

($ok, $error) = check($resolute . "releases:\n- name: rustfs\n  version: 0.2.0+dev.1\n");
ok(!$ok, 'a manifest without bpm is refused');

($ok, $error) = check(bpm('1.4.41'));
ok(!$ok, 'a manifest without stemcells is refused');

{
	local $ENV{GENESIS_MANIFEST_FILE} = "$work/missing.yml";
	my $hook = bless {label => 'pre-deploy'}, 'Genesis::Hook::PreDeploy::RustFS';
	ok(!eval { $hook->_check_resolute; 1 }, 'a missing manifest is refused');
}

# ---- noble bpm ------------------------------------------------------------

sub manifest_of {
	my ($yaml) = @_;
	open(my $fh, '>', "$work/manifest.yml") or die;
	print {$fh} $yaml;
	close($fh);
	local $ENV{GENESIS_MANIFEST_FILE} = "$work/manifest.yml";
	return bless({label => 'pre-deploy'}, 'Genesis::Hook::PreDeploy::RustFS')->_manifest;
}

sub noble_ok {
	my ($yaml) = @_;
	my $manifest = manifest_of($yaml);
	my $hook = bless {label => 'pre-deploy'}, 'Genesis::Hook::PreDeploy::RustFS';
	my $ok = eval { $hook->_check_noble_bpm($manifest); 1 };
	return ($ok, $@ // '');
}

($ok, $error) = noble_ok($noble . bpm('1.4.22'));
ok($ok, 'noble with bpm 1.4.22 passes') or diag($error);

($ok, $error) = noble_ok($noble . bpm('1.4.31'));
ok(!$ok, 'noble with bpm 1.4.31 is refused');
like($error, qr/1\.4\.31/, 'the refusal names bpm 1.4.31');

($ok, $error) = noble_ok($noble . bpm('latest'));
ok(!$ok, 'noble with bpm latest is refused');

($ok, $error) = noble_ok($noble . "releases:\n- name: bpm\n");
ok(!$ok, 'noble with a bpm release that has no version is refused');

# ---- stub environment --------------------------------------------------

package StubVault {
	sub new { my ($c, %o) = @_; bless {%o, calls => []}, $c }
	sub get {
		my ($self, $path, $key) = @_;
		push @{$self->{calls}}, "$path:$key";
		return $self->{data}{"$path:$key"};
	}
}

package StubBosh {
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub execute {
		my ($self, $opts, @args) = @_;
		die "unexpected bosh command: @args\n" unless $args[0] eq 'instances';
		die "bosh is unreachable\n" if ($self->{rc} // 0) eq 'die';
		return ($self->{out} // '', $self->{rc} // 0, $self->{err} // '');
	}
}

package StubEnv {
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub name { 'spec' }
	sub deployment_name { 'spec-rustfs' }
	sub secrets_base { '/secret/spec/rustfs/' }
	sub vault { $_[0]{vault} }
	sub bosh { $_[0]{bosh} }
	sub manifest_lookup {
		my ($self, $key, $default) = @_;
		return exists($self->{meta}{$key}) ? $self->{meta}{$key} : $default;
	}
	sub lookup {
		my ($self, $key, $default) = @_;
		return exists($self->{params}{$key}) ? $self->{params}{$key} : $default;
	}
	sub exodus_lookup {
		my ($self, $key, $default) = @_;
		return exists($self->{exodus}{$key}) ? $self->{exodus}{$key} : $default;
	}
}

package main;

# flat strips colour codes and the terminal wrapping from an error.
sub flat { (my $e = $_[0] // '') =~ s/\e\[[0-9;]*m//g; $e =~ s/\s+/ /g; $e }

sub hook_with { bless {label => 'pre-deploy', env => StubEnv->new(@_)}, 'Genesis::Hook::PreDeploy::RustFS' }

# Quiet the hook's informational output.
{
	no warnings 'redefine';
	*Genesis::Hook::PreDeploy::RustFS::info    = sub {};
	*Genesis::Hook::PreDeploy::RustFS::warning = sub {};
}

# ---- API certificate addresses -------------------------------------------

chomp(my $openssl = `command -v openssl`);
SKIP: {
	skip 'openssl is not installed', 9 unless $openssl;

	# cert_naming makes a throwaway self-signed certificate that names the
	# given addresses.  Its key never leaves the temporary directory.
	my $n = 0;
	my $cert_naming = sub {
		my $san = join(',', map {"IP:$_"} @_);
		$n++;
		system($openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
			'-subj', '/CN=rustfs.bosh', '-addext', "subjectAltName=DNS:rustfs.bosh,$san",
			'-keyout', "$work/k$n.pem", '-out', "$work/c$n.pem") == 0
			and -s "$work/c$n.pem" or die "could not make a test certificate";
		open(my $fh, '<', "$work/c$n.pem") or die;
		return do { local $/; <$fh> };
	};
	open(my $saved, '>&', \*STDERR) or die;
	open(STDERR, '>', '/dev/null');
	my $full = $cert_naming->('127.0.0.1', '10.99.1.30', '10.99.2.30', '10.99.3.30');
	my $old  = $cert_naming->('127.0.0.1', '10.99.1.30', '10.99.2.30');
	my $v6   = $cert_naming->('127.0.0.1', 'fd00:0:0:0:0:0:0:5');
	my $none = $cert_naming->('127.0.0.1');
	open(STDERR, '>&', $saved);

	my $ips = {'meta.api_cert_ips' => ['10.99.1.30', '10.99.2.30', '10.99.3.30']};
	my $path = '/secret/spec/rustfs/certs/api:certificate';

	my $vault = StubVault->new(data => {$path => $full});
	ok(eval { hook_with(meta => $ips, vault => $vault)->_check_api_cert({}); 1 },
		'a certificate that names every node address passes') or diag($@);
	is_deeply($vault->{calls}, [$path], 'only the public certificate is read, never the key');

	ok(!eval { hook_with(meta => $ips, vault => StubVault->new(data => {$path => $old}))->_check_api_cert({}); 1 },
		'a certificate that misses a node address is refused');
	like(flat($@), qr/missing 10\.99\.3\.30/, 'the refusal names the missing address');
	like(flat($@), qr/genesis spec rotate-secrets certs\/api/, 'the refusal says how to renew the certificate');

	ok(eval { hook_with(meta => {'meta.api_cert_ips' => ['fd00::5']}, vault => StubVault->new(data => {$path => $v6}))->_check_api_cert({}); 1 },
		'an IPv6 address matches however it is spelled') or diag($@);

	ok(eval { hook_with(meta => {}, vault => StubVault->new(data => {$path => $none}))->_check_api_cert({}); 1 },
		'a single node without params.ips needs only 127.0.0.1') or diag($@);

	ok(!eval { hook_with(meta => $ips, vault => StubVault->new(data => {}))->_check_api_cert({}); 1 },
		'a missing certificate is refused');
	like(flat($@), qr/add-secrets/, 'the refusal says to run add-secrets');
}

# ---- node count ----------------------------------------------------------

sub group_of { {instance_groups => [{name => 'rustfs', instances => $_[0]}, {name => 'smoke-tests', instances => 1}]} }
sub bosh_rows {
	my @rows = map {{instance => $_}} @_;
	return StubBosh->new(out => JSON::PP->new->encode({Tables => [{Rows => \@rows}]}));
}
my @three = map {"rustfs/$_"} qw/a b c/;

ok(eval { hook_with(bosh => bosh_rows(@three, 'smoke-tests/z'))->_check_node_count(group_of(3)); 1 },
	'an unchanged node count passes, and errand VMs are not counted') or diag($@);

ok(!eval { hook_with(bosh => bosh_rows(@three))->_check_node_count(group_of(4)); 1 },
	'growing a cluster is refused');
like(flat($@), qr/from 3 \(from BOSH\) to 4/, 'the refusal names both counts and the source');
like(flat($@), qr/allow_node_count_change/, 'the refusal names the override');
like(flat($@), qr/"Changing the Node Count" in the kit manual \(genesis spec kit-manual\)/, 'the refusal points to the manual section');
like(flat($@), qr/mc mirror/, 'the refusal names the copy tool');

ok(!eval { hook_with(bosh => bosh_rows(@three))->_check_node_count(group_of(1)); 1 },
	'shrinking a cluster to one node is refused');

ok(eval { hook_with(bosh => bosh_rows(@three), params => {'params.allow_node_count_change' => 1})->_check_node_count(group_of(5)); 1 },
	'the override lets a cluster change size') or diag($@);

ok(!eval { hook_with(bosh => bosh_rows('rustfs/a'), params => {'params.allow_node_count_change' => 1})->_check_node_count(group_of(3)); 1 },
	'growing a single node is refused even with the override');
like(flat($@), qr/unsupported pool expansion/, 'the refusal quotes the RustFS error');
like(flat($@), qr/new deployment at the new size .* mc mirror/, 'the refusal names the supported migration');
like(flat($@), qr/"Changing the Node Count" in the kit manual \(genesis spec kit-manual\)/, 'the refusal points to the manual section');

ok(eval { hook_with(bosh => StubBosh->new(rc => 1, err => "Deployment 'spec-rustfs' doesn't exist"), exodus => {instances => 1})->_check_node_count(group_of(3)); 1 },
	'a first deploy passes, even when stale exodus data remains') or diag($@);

ok(!eval { hook_with(bosh => StubBosh->new(rc => 'die'), exodus => {instances => 3})->_check_node_count(group_of(4)); 1 },
	'without BOSH the exodus count is used');
like(flat($@), qr/from the exodus data/, 'the refusal names the exodus data as the source');

ok(eval { hook_with(bosh => StubBosh->new(rc => 'die'), exodus => {})->_check_node_count(group_of(4)); 1 },
	'with no deployed count to compare, the check passes') or diag($@);

done_testing();
