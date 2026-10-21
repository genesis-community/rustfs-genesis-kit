#!/usr/bin/env perl
# Proves that the mc addon configures the alias with the secret key on mc's
# stdin, never on a command line and never in what it prints, and that it
# installs the kit CA so that mc verifies the API certificate.
#
# Each case hands the hook a stub environment and puts a fake mc on the
# PATH.  The fake records its arguments and its stdin, so the test can see
# exactly what mc received.  Run it with `prove spec/hooks` or
# `perl spec/hooks/addon-mc.t`.

use v5.20;
use warnings;

use Cwd qw/abs_path/;
use File::Basename qw/dirname/;
use File::Path qw/make_path/;
use File::Temp qw/tempdir/;
use Test::More;

BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

my $hooks = abs_path(dirname(__FILE__).'/../../hooks');
require "$hooks/addon-mc~m.pm";

my $class = 'Genesis::Hook::Addon::RustFS::Mc';

my $secret = 'sEcReT/with+chars$and spaces';
my $ca     = "-----BEGIN CERTIFICATE-----\nMIIBfakeca\n-----END CERTIFICATE-----\n";

# Capture what the hook prints, and turn bail into a die that the test can
# catch, instead of sending either through the Genesis logger.
my @printed;
{
	no strict 'refs';
	no warnings 'redefine';
	*{"${class}::info"} = sub {
		my ($fmt, @args) = @_;
		$fmt = '' unless defined($fmt);
		push @printed, @args ? sprintf($fmt, @args) : $fmt;
	};
	*{"${class}::bail"} = sub {
		my ($fmt, @args) = @_;
		die((@args ? sprintf($fmt, @args) : $fmt) . "\n");
	};
}

package StubVault {
	sub new { my ($c, %o) = @_; bless {%o, calls => []}, $c }
	sub name { 'spec-vault' }
	sub get {
		my ($self, $path, $key) = @_;
		push @{$self->{calls}}, "$path:$key";
		return $self->{data}{"$path:$key"};
	}
}

package StubEnv {
	sub new { my ($c, %o) = @_; bless {%o}, $c }
	sub name { 'spec-lab' }
	sub secrets_base { '/secret/spec/lab/rustfs/' }
	sub vault { $_[0]{vault} }
	sub exodus_lookup {
		my ($self, $key, $default) = @_;
		return exists($self->{exodus}{$key}) ? $self->{exodus}{$key} : $default;
	}
}

package main;

sub slurp { my ($f) = @_; open(my $fh, '<', $f) or return undef; local $/; my $s = <$fh>; close $fh; $s }

# fake_mc writes an mc that records its arguments and stdin, and exits with
# the given status after printing the given text.
sub fake_mc {
	my ($bin, $status, $say) = @_;
	make_path($bin);
	open(my $fh, '>', "$bin/mc") or die "cannot write fake mc: $!";
	print $fh "#!/bin/sh\n",
		"for a in \"\$@\"; do printf '%s\\n' \"\$a\"; done > \"\$FAKE_MC_DIR/args\"\n",
		"cat > \"\$FAKE_MC_DIR/stdin\"\n",
		"printf '%s\\n' '$say'\n",
		"exit $status\n";
	close $fh;
	chmod 0755, "$bin/mc";
}

# run_hook runs perform in a fresh HOME with the given stubs, and returns
# the hook result (or the bail text), what it printed, and the work dir.
sub run_hook {
	my (%o) = @_;
	@printed = ();
	my $work = tempdir('rustfs-mc-test-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	my $bin  = "$work/bin";
	make_path($bin);
	fake_mc($bin, $o{mc_status} // 0, $o{mc_says} // 'Added `rustfs-spec-lab` successfully.') unless $o{no_mc};
	local $ENV{HOME} = "$work/home";
	local $ENV{PATH} = $o{no_mc} ? $bin : "$bin:/usr/bin:/bin";
	local $ENV{FAKE_MC_DIR} = $work;
	my $vault = StubVault->new(data => {'/secret/spec/lab/rustfs/credentials:secret_key' => exists($o{secret}) ? $o{secret} : "$secret\n"});
	my $env = StubEnv->new(vault => $vault, exodus => $o{exodus} // {
		s3_api_url => 'https://10.99.1.30:9000', access_key => 'AKSPEC', ca => $ca,
	});
	my $hook = bless {env => $env, complete => 0}, $class;
	my $result = eval { $hook->perform };
	my $error = $@;
	return ($result, $error, join("\n", @printed), $work, $vault);
}

# ---- the alias -----------------------------------------------------------

{
	my ($result, $error, $out, $work) = run_hook();
	is($error, '', 'the addon completes') or diag $error;
	is($result, 1, 'the addon reports success');
	is(slurp("$work/args"), "alias\nset\nrustfs-spec-lab\nhttps://10.99.1.30:9000\n",
		'mc gets only the alias and the URL as arguments');
	is(slurp("$work/stdin"), "AKSPEC\n$secret\n", 'mc reads the access key and then the secret key from stdin');
	unlike($out, qr/\Q$secret\E/, 'the secret key is never printed');
	unlike($out, qr/--insecure/, 'no printed command skips certificate verification');
	like($out, qr/mc ls rustfs-spec-lab/, 'the usage examples use the alias');
	my $ca_file = "$work/home/.mc/certs/CAs/rustfs-spec-lab.crt";
	is(slurp($ca_file), $ca, 'the kit CA is installed where mc trusts it');
	like($out, qr/\Q$ca_file\E/, 'the addon says where it installed the CA');
}

# ---- failures ------------------------------------------------------------

{
	my ($result, $error, $out, $work) = run_hook(mc_status => 1, mc_says => "Unable to initialize alias with $secret");
	like($error, qr/mc alias set rustfs-spec-lab https:\/\/10\.99\.1\.30:9000 failed \(exit 1\)/, 'a failing mc stops the addon');
	unlike($error, qr/\Q$secret\E/, 'mc output that echoes the secret is redacted');
	like($error, qr/<redacted>/, 'the redaction is visible');
}

{
	my ($result, $error, $out, $work, $vault) = run_hook(no_mc => 1);
	like($error, qr/mc is not on the PATH/, 'a missing mc stops the addon');
	like($error, qr/safe -T spec-vault get \/secret\/spec\/lab\/rustfs\/credentials:secret_key/,
		'the manual recipe reads the secret through safe');
	like($error, qr/\| mc alias set rustfs-spec-lab https:\/\/10\.99\.1\.30:9000$/m, 'the manual recipe pipes the keys to mc');
	unlike($error, qr/\Q$secret\E/, 'the manual recipe does not include the secret');
	is(scalar(@{$vault->{calls}}), 0, 'the secret is not even read when mc is missing');
}

{
	my ($result, $error) = run_hook(secret => undef);
	like($error, qr/Could not read secret_key from \/secret\/spec\/lab\/rustfs\/credentials/, 'a missing secret stops the addon');
}

{
	my ($result, $error) = run_hook(exodus => {access_key => 'AKSPEC'});
	like($error, qr/Could not read s3_api_url/, 'missing exodus data stops the addon');
}

{
	my ($result, $error, $out, $work) = run_hook(exodus => {s3_api_url => 'https://10.99.1.30:9000', access_key => 'AKSPEC'});
	is($error, '', 'an https URL without a CA still configures the alias') or diag $error;
	is(slurp("$work/args"), "alias\nset\n--insecure\nrustfs-spec-lab\nhttps://10.99.1.30:9000\n",
		'without a CA the alias skips verification');
	like($out, qr/Warning.*no CA/, 'and the addon warns about it');
	like($out, qr/mc --insecure ls rustfs-spec-lab/, 'the usage examples carry --insecure');
}

done_testing;
