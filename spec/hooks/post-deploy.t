#!/usr/bin/env perl
# Proves that the post-deploy hook probes every RustFS node over https, on the
# readiness endpoint, with the kit CA, and that every outcome of the probe is
# reported as information or a warning rather than a failure.
#
# The hook talks to BOSH through $env->bosh->execute, so each case hands the
# hook a stub environment whose BOSH answers are scripted.  The probe command
# itself is also run through a local shell, with stub sudo and curl commands,
# so the shell logic that picks the marker is tested as well.  Run it with
# `prove spec/hooks` or `perl spec/hooks/post-deploy.t`.

use v5.20;
use warnings;

use Cwd qw/abs_path/;
use File::Basename qw/dirname/;
use File::Temp qw/tempdir/;
use Test::More;

BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

my $hooks = abs_path(dirname(__FILE__).'/../../hooks');
my $work  = tempdir('rustfs-postdeploy-test-XXXXXX', TMPDIR => 1, CLEANUP => 1);
require "$hooks/post-deploy.pm";

my $class = 'Genesis::Hook::PostDeploy::RustFS';

# Capture what the hook prints, instead of sending it through the Genesis
# logger.
my @printed;
{
	no strict 'refs';
	no warnings 'redefine';
	*{"${class}::info"} = sub {
		my ($fmt, @args) = @_;
		$fmt = '' unless defined($fmt);
		push @printed, @args ? sprintf($fmt, @args) : $fmt;
	};
}
sub printed { join("\n", @printed) }

# A stub BOSH director.  `instances` answers with the given JSON and exit
# code.  `ssh` answers from a per-target table, or dies when the table holds
# the word "die".
package StubBosh {
	sub new { my ($c, %o) = @_; bless {%o, calls => []}, $c }
	sub calls { @{$_[0]{calls}} }
	sub execute {
		my ($self, $opts, @args) = @_;
		push @{$self->{calls}}, [$opts, @args];
		if ($args[0] eq 'instances') {
			die "bosh is unreachable\n" if ($self->{instances_rc} // 0) eq 'die';
			return ($self->{instances_json}, $self->{instances_rc} // 0);
		}
		if ($args[0] eq 'ssh') {
			my $answer = $self->{ssh}{$args[1]} // ["", 1];
			die "ssh failed\n" if !ref($answer) && $answer eq 'die';
			return @$answer;
		}
		die "unexpected bosh command: @args\n";
	}
}

# A stub environment with the exodus data and parameters the hook reads.
package StubEnv {
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub bosh { $_[0]{bosh} }
	sub features { @{$_[0]{features} // []} }
	sub deployment_name { 'spec-rustfs' }
	sub exodus_lookup {
		my ($self, $key, $default) = @_;
		my $value = exists($self->{exodus}{$key}) ? $self->{exodus}{$key} : $default;
		return wantarray ? ($value, $key) : $value;
	}
	sub lookup {
		my ($self, $key, $default) = @_;
		my $value = exists($self->{params}{$key}) ? $self->{params}{$key} : $default;
		return wantarray ? ($value, $key) : $value;
	}
}

package main;

$ENV{GENESIS_ENVIRONMENT} = 'spec-rustfs';

# instances_json lists instances by name, or by [name, ips] pairs.
sub instances_json {
	my @rows = map {
		ref($_) ? {instance => $_->[0], ips => $_->[1], process_state => 'running'}
		        : {instance => $_, process_state => 'running'}
	} @_;
	return JSON::PP->new->encode({Tables => [{Rows => \@rows}]});
}

# run_hook runs perform with the given deploy return code and stubs, and
# returns the hook, the stub BOSH, and what the hook printed.
sub run_hook {
	my (%o) = @_;
	@printed = ();
	my $bosh = StubBosh->new(%{$o{bosh} // {}});
	my $env  = StubEnv->new(
		bosh   => $bosh,
		exodus => $o{exodus} // {s3_api_url => 'https://10.99.1.30:9000', s3_console_url => 'https://10.99.1.30:9001', instances => 3},
		params => $o{params} // {},
		features => $o{features} // [],
	);
	my $hook = bless {env => $env, rc => $o{rc}, complete => 0}, $class;
	local $ENV{GENESIS_DEPLOY_RC};
	if (defined($o{env_rc})) { $ENV{GENESIS_DEPLOY_RC} = $o{env_rc} } else { delete $ENV{GENESIS_DEPLOY_RC} }
	my $result = $hook->perform;
	return ($hook, $bosh, printed(), $result);
}

sub ssh_targets { map {$_->[2]} grep {$_->[1] eq 'ssh'} $_[0]->calls }

my $ok_marker = ["Task 1 | rustfs/a: stdout | RUSTFS_PROBE=verified\n", 0];

# ---- deploy result -------------------------------------------------------

for my $case ([1, undef, 'a failed deploy'], [undef, undef, 'a missing return code'], ['', undef, 'an empty return code'], [undef, '2', 'a failed deploy in GENESIS_DEPLOY_RC']) {
	my ($rc, $env_rc, $name) = @$case;
	my ($hook, $bosh, $out, $result) = run_hook(rc => $rc, env_rc => $env_rc);
	is($result, 1, "$name still completes the hook");
	is(scalar($bosh->calls), 0, "$name makes no BOSH calls");
	like($out, qr/Deployment failed/, "$name is reported as a failed deploy");
}

{
	my ($hook, $bosh, $out) = run_hook(env_rc => '0', bosh => {
		instances_json => instances_json('rustfs/a'), ssh => {'rustfs/a' => $ok_marker},
	});
	is_deeply([ssh_targets($bosh)], ['rustfs/a'], 'GENESIS_DEPLOY_RC=0 counts as a successful deploy');
}

# ---- targets -------------------------------------------------------------

{
	my ($hook, $bosh, $out, $result) = run_hook(rc => 0, bosh => {
		instances_json => instances_json('rustfs/a1 (bootstrap)', 'rustfs/b2', 'smoke-tests/c3'),
		ssh => {'rustfs/a1' => $ok_marker, 'rustfs/b2' => $ok_marker},
	});
	is($result, 1, 'a successful deploy completes the hook');
	is_deeply([ssh_targets($bosh)], ['rustfs/a1', 'rustfs/b2'],
		'every rustfs instance BOSH lists is probed, without the bootstrap suffix or errand VMs');
	my ($list) = grep {$_->[1] eq 'instances'} $bosh->calls;
	is($list->[0]{deployment}, 'spec-rustfs', 'the instance list is read for this deployment');
	is($list->[2], '--json', 'the instance list is read as JSON');
	like($out, qr/Instances:\s+#C\{2\}/, 'the instance count comes from BOSH');
	like($out, qr{https://10\.99\.1\.30:9000}, 'the S3 API URL comes from the exodus data');
	unlike($out, qr/BOSH did not list/, 'no fallback note when BOSH lists the instances');
}

for my $case (
	[{instances_rc => 1, instances_json => ''}, 'a failed instance listing'],
	[{instances_rc => 'die'}, 'an unreachable director'],
	[{instances_json => 'not json'}, 'an unreadable instance listing'],
	[{instances_json => instances_json()}, 'an empty instance listing'],
) {
	my ($bosh_opts, $name) = @$case;
	my ($hook, $bosh, $out) = run_hook(rc => 0, bosh => {%$bosh_opts, ssh => {map {("rustfs/$_" => $ok_marker)} 0..2}});
	is_deeply([ssh_targets($bosh)], ['rustfs/0', 'rustfs/1', 'rustfs/2'],
		"$name falls back to the exodus instance count");
	like($out, qr/BOSH did not list the instances/, "$name is noted");
}

for my $count (undef, 'three', 0, [3]) {
	my $label = defined($count) ? (ref($count) ? 'a list' : "'$count'") : 'no value';
	my ($hook, $bosh) = run_hook(rc => 0,
		exodus => {defined($count) ? (instances => $count) : ()},
		bosh   => {instances_rc => 1, instances_json => '', ssh => {'rustfs/0' => $ok_marker}},
	);
	is_deeply([ssh_targets($bosh)], ['rustfs/0'], "an exodus instance count of $label falls back to one node");
}

{
	my ($hook, $bosh, $out) = run_hook(rc => 0, exodus => {},
		bosh => {instances_json => instances_json('rustfs/a'), ssh => {'rustfs/a' => $ok_marker}});
	like($out, qr/S3 API URL:\s+#G\{\(unknown\)\}/, 'a missing S3 API URL is reported as unknown');
}

# ---- probe command -------------------------------------------------------

{
	my ($hook, $bosh) = run_hook(rc => 0, bosh => {
		instances_json => instances_json('rustfs/a'), ssh => {'rustfs/a' => $ok_marker},
	});
	my ($ssh) = grep {$_->[1] eq 'ssh'} $bosh->calls;
	is($ssh->[0]{deployment}, 'spec-rustfs', 'the probe runs against this deployment');
	is($ssh->[3], '--command', 'the probe passes a command to bosh ssh');
	is($ssh->[5], '--results', 'the probe asks bosh ssh for results');
	my $cmd = $ssh->[4];
	like($cmd, qr{url=https://127\.0\.0\.1:9000/health/ready}, 'the probe dials https on the readiness endpoint');
	unlike($cmd, qr{http://}, 'the probe never dials plain http');
	like($cmd, qr{ca=/var/vcap/jobs/rustfs-server/tls/ca\.crt}, 'the probe reads the kit CA from the job');
	like($cmd, qr{--cacert "\$ca"}, 'the verified probe checks the certificate against the kit CA');
	unlike($cmd, qr/RUSTFS_PROBE=/, 'the command text never contains a complete marker');
}

for my $case ([8443, 8443], ['8443', 8443], [0, 9000], [70000, 9000], ['https', 9000], [[1], 9000]) {
	my ($port, $expect) = @$case;
	my ($hook, $bosh) = run_hook(rc => 0, params => {'params.rustfs_port' => $port}, bosh => {
		instances_json => instances_json('rustfs/a'), ssh => {'rustfs/a' => $ok_marker},
	});
	my ($ssh) = grep {$_->[1] eq 'ssh'} $bosh->calls;
	my $label = ref($port) ? 'a list' : $port;
	like($ssh->[4], qr{https://127\.0\.0\.1:$expect/health/ready}, "params.rustfs_port $label probes port $expect");
}

# ---- probe address -------------------------------------------------------

{
	my ($hook, $bosh, $out) = run_hook(rc => 0,
		params => {'params.ips' => ['10.99.1.30', '10.99.2.30']},
		bosh => {
			instances_json => instances_json(['rustfs/a', '10.99.1.30'], ['rustfs/b', '10.99.2.30']),
			ssh => {'rustfs/a' => $ok_marker, 'rustfs/b' => $ok_marker},
		});
	my @cmds = map {$_->[4]} grep {$_->[1] eq 'ssh'} $bosh->calls;
	like($cmds[0], qr{url=https://10\.99\.1\.30:9000/health/ready}, 'with params.ips the probe dials the first node at its own address');
	like($cmds[1], qr{url=https://10\.99\.2\.30:9000/health/ready}, 'with params.ips the probe dials the second node at its own address');
	unlike($out, qr/params\.ips is not set/, 'no loopback note when params.ips is set');
}

{
	my ($hook, $bosh) = run_hook(rc => 0, features => ['ocfp'], bosh => {
		instances_json => instances_json(['rustfs/a', 'fd00::5']),
		ssh => {'rustfs/a' => $ok_marker},
	});
	my ($ssh) = grep {$_->[1] eq 'ssh'} $bosh->calls;
	like($ssh->[4], qr{url=https://\[fd00::5\]:9000/health/ready}, 'under ocfp the probe dials the node address, bracketed for IPv6');
	like($ssh->[4], qr{curl -g }, 'the probe tells curl not to glob the brackets');
}

{
	my ($hook, $bosh, $out) = run_hook(rc => 0,
		params => {'params.ips' => ['10.99.1.30', '10.99.2.30', '10.99.3.30']},
		exodus => {instances => 3, ips => '10.99.1.30,10.99.2.30,10.99.3.30'},
		bosh => {instances_rc => 1, instances_json => '', ssh => {map {("rustfs/$_" => $ok_marker)} 0..2}});
	my @cmds = map {$_->[4]} grep {$_->[1] eq 'ssh'} $bosh->calls;
	like($cmds[2], qr{url=https://10\.99\.3\.30:9000/}, 'without BOSH the node addresses come from the exodus ips');
}

{
	my ($hook, $bosh, $out) = run_hook(rc => 0, bosh => {
		instances_json => instances_json(['rustfs/a', '10.99.1.30']),
		ssh => {'rustfs/a' => $ok_marker},
	});
	my ($ssh) = grep {$_->[1] eq 'ssh'} $bosh->calls;
	like($ssh->[4], qr{url=https://127\.0\.0\.1:9000/}, 'without params.ips the probe dials loopback, which the certificate names');
	like($out, qr/params\.ips is not set/, 'the loopback probe is noted');
}

# ---- probe results -------------------------------------------------------

for my $case (
	["RUSTFS_PROBE=verified",        'verified',        qr/\[ok\].*certificate verified against the kit CA/],
	["RUSTFS_PROBE=unverified:cert", 'unverified:cert', qr/\[warn\].*did not verify against the kit CA.*certs\/api/],
	["RUSTFS_PROBE=unverified:noca", 'unverified:noca', qr/\[warn\].*kit CA could not be read/],
	["RUSTFS_PROBE=failed:22",       'failed:22',       qr/\[warn\].*curl exit 22.*converging/],
	["no marker at all",             'error',           qr/\[warn\].*printed no result/],
	["RUSTFS_PROBE=bogus",           'error',           qr/\[warn\].*printed no result/],
) {
	my ($stdout, $expect, $message) = @$case;
	@printed = ();
	my $bosh = StubBosh->new(ssh => {'rustfs/a' => ["rustfs/a: stdout | $stdout\n", 0]});
	my $hook = bless {env => StubEnv->new(bosh => $bosh)}, $class;
	is($hook->_probe_node('rustfs/a', 9000, '10.99.1.30'), $expect, "'$stdout' is read as $expect");
	like(printed(), $message, "'$stdout' is reported");
}

for my $case ([["", 1], qr/could not run the health probe on rustfs\/a \(exit 1\)/, 'a non-zero bosh ssh exit'],
              ['die',   qr/could not run the health probe on rustfs\/a \(bosh ssh failed\)/, 'a bosh ssh error'],
              [["", undef], qr/could not run the health probe on rustfs\/a \(exit unknown\)/, 'a missing bosh ssh exit code']) {
	my ($answer, $message, $name) = @$case;
	@printed = ();
	my $bosh = StubBosh->new(ssh => {'rustfs/a' => $answer});
	my $hook = bless {env => StubEnv->new(bosh => $bosh)}, $class;
	is($hook->_probe_node('rustfs/a', 9000), 'error', "$name is an error result");
	like(printed(), $message, "$name is reported as a warning");
}

{
	my ($hook, $bosh, $out, $result) = run_hook(rc => 0, bosh => {
		instances_json => instances_json('rustfs/a', 'rustfs/b'),
		ssh => {'rustfs/a' => 'die', 'rustfs/b' => ["RUSTFS_PROBE=failed:7\n", 0]},
	});
	is($result, 1, 'probe failures never fail the hook');
	is_deeply([ssh_targets($bosh)], ['rustfs/a', 'rustfs/b'], 'a failed probe does not stop the others');
}

# ---- probe shell logic ---------------------------------------------------
#
# Each case runs the probe command in a local shell whose PATH holds stub
# sudo and curl commands.  The stub sudo drops -n and runs its command, or
# refuses when SUDO_FAILS is set.  The stub curl records its arguments and
# exits with CURL_VERIFIED_RC when given --cacert, or CURL_INSECURE_RC when
# given -k.  grep is the real one, run against a CA file the case writes.

my $bin = "$work/bin";
mkdir $bin or die "mkdir $bin: $!";
sub write_script {
	my ($path, $body) = @_;
	open(my $fh, '>', $path) or die "write $path: $!";
	print {$fh} $body;
	close($fh);
	chmod 0755, $path or die "chmod $path: $!";
}
write_script("$bin/sudo", <<'EOF');
#!/bin/sh
[ -n "$SUDO_FAILS" ] && exit 1
[ "$1" = "-n" ] && shift
exec "$@"
EOF
write_script("$bin/curl", <<'EOF');
#!/bin/sh
echo "$*" >> "$CURL_LOG"
for a in "$@"; do
  case "$a" in
    --cacert) exit "${CURL_VERIFIED_RC:-0}" ;;
    -fsSk) exit "${CURL_INSECURE_RC:-0}" ;;
  esac
done
exit 99
EOF
chomp(my $grep_path = `command -v grep`);
symlink($grep_path, "$bin/grep") or die "symlink grep: $!";

sub probe_shell {
	my (%o) = @_;
	my $cmd = $class->_probe_command(9000);
	my $ca = "$work/ca.crt";
	unlink $ca;
	if (defined($o{ca})) {
		open(my $fh, '>', $ca) or die;
		print {$fh} $o{ca};
		close($fh);
	}
	$cmd =~ s{ca=/var/vcap/jobs/rustfs-server/tls/ca\.crt}{ca=$ca} or die "the probe command names no CA file";
	my $log = "$work/curl.log";
	unlink $log;
	local %ENV = (
		PATH => $bin,
		CURL_LOG => $log,
		defined($o{verified_rc}) ? (CURL_VERIFIED_RC => $o{verified_rc}) : (),
		defined($o{insecure_rc}) ? (CURL_INSECURE_RC => $o{insecure_rc}) : (),
		$o{sudo_fails} ? (SUDO_FAILS => 1) : (),
	);
	open(my $sh, '-|', '/bin/sh', '-c', $cmd) or die "run probe: $!";
	my $out = do { local $/; <$sh> };
	close($sh);
	my $rc = $? >> 8;
	my @curls = -f $log ? do { open(my $fh, '<', $log) or die; <$fh> } : ();
	return ($out, $rc, scalar(@curls));
}

my $pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n";
for my $case (
	[{ca => $pem},                                     'RUSTFS_PROBE=verified',        1, 'a certificate that verifies'],
	[{ca => $pem, verified_rc => 60},                  'RUSTFS_PROBE=unverified:cert', 2, 'a certificate that does not verify'],
	[{ca => $pem, verified_rc => 60, insecure_rc => 7}, 'RUSTFS_PROBE=failed:7',       2, 'a node that fails without verification too'],
	[{ca => $pem, verified_rc => 77},                  'RUSTFS_PROBE=unverified:noca', 2, 'a CA file curl cannot read'],
	[{ca => $pem, verified_rc => 22},                  'RUSTFS_PROBE=failed:22',       1, 'a node that is not ready'],
	[{ca => $pem, verified_rc => 7},                   'RUSTFS_PROBE=failed:7',        1, 'a node that refuses the connection'],
	[{ca => "empty\n"},                                'RUSTFS_PROBE=unverified:noca', 1, 'a CA file with no certificate'],
	[{},                                               'RUSTFS_PROBE=unverified:noca', 1, 'a missing CA file'],
	[{ca => $pem, sudo_fails => 1},                    'RUSTFS_PROBE=unverified:noca', 1, 'a user without sudo'],
	[{sudo_fails => 1, insecure_rc => 35},             'RUSTFS_PROBE=failed:35',       1, 'a failed unverified probe'],
) {
	my ($opts, $expect, $curls, $name) = @$case;
	my ($out, $rc, $calls) = probe_shell(%$opts);
	is($rc, 0, "the probe shell exits 0 for $name");
	is($out, "$expect\n", "the probe shell prints $expect for $name");
	is($calls, $curls, "the probe shell runs curl $curls time(s) for $name");
}

done_testing();
