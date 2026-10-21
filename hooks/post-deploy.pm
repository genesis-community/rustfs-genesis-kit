package Genesis::Hook::PostDeploy::RustFS v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info/;
use JSON::PP ();

# The CA certificate that the rustfs-server job renders from rustfs.tls.ca.
use constant CA_FILE => '/var/vcap/jobs/rustfs-server/tls/ca.crt';

# init - Initialize the hook {{{
sub init {
  my ($class, %ops) = @_;
  my $obj = $class->SUPER::init(%ops);
  $obj->check_minimum_genesis_version('3.1.0');
  return $obj;
}
# }}}

# perform - Main hook execution {{{
sub perform {
  my ($self) = @_;

  # A missing return code is not a success.  Genesis passes it to the hook
  # and also exports it, so read either one, and treat anything other than
  # a plain 0 as a failed deploy.
  my $rc = defined($self->{rc}) ? $self->{rc} : $ENV{GENESIS_DEPLOY_RC};
  unless (defined($rc) && $rc =~ /^\s*0\s*$/) {
    info("#R{Deployment failed} - skipping post-deploy actions");
    return $self->done(1);
  }

  info("");
  info("#M{$ENV{GENESIS_ENVIRONMENT}} RustFS deployed successfully!");
  info("");

  my $env = $self->env;

  # Read the exodus data this deploy just exported.  exodus_lookup returns
  # a value and key pair in list context, so each call is made scalar.
  my $s3_api_url     = scalar($env->exodus_lookup('s3_api_url', undef))     // '(unknown)';
  my $s3_console_url = scalar($env->exodus_lookup('s3_console_url', undef)) // '(unknown)';

  # The probe targets come from BOSH.  Without it, fall back to the exodus
  # instance count and probe rustfs/0 through rustfs/N-1, taking each
  # node's address from the exodus ips list.
  my @targets = $self->_rustfs_instances;
  my $from_bosh = scalar(@targets);
  unless (@targets) {
    my $count = scalar($env->exodus_lookup('instances', undef));
    $count = 1 unless defined($count) && !ref($count) && $count =~ /^[1-9][0-9]*$/;
    my $ips = scalar($env->exodus_lookup('ips', undef));
    my @ips = defined($ips) && !ref($ips) ? split(/\s*,\s*/, $ips) : ();
    @targets = map {{name => "rustfs/$_", ip => $ips[$_]}} (0 .. $count - 1);
  }

  info("  S3 API URL:     #G{%s}", $s3_api_url);
  info("  Console URL:    #G{%s}", $s3_console_url);
  info("  Instances:      #C{%d}", scalar(@targets));
  info("");

  # Every node serves https only.  The probe dials each node at its own IP
  # address, the name that peers and clients use, and verifies the
  # certificate against the kit CA with that address as the name.  When the
  # kit does not know the addresses, as for a single node without
  # params.ips, the certificate names only 127.0.0.1, so the probe dials
  # that instead.  Failures are warnings, because the cluster may still be
  # converging.
  info("  #Y{[note]} BOSH did not list the instances, so the probes assume rustfs/0 to rustfs/%d", scalar(@targets) - 1)
    unless $from_bosh;
  my $port = scalar($env->lookup('params.rustfs_port', 9000));
  $port = 9000 unless defined($port) && !ref($port) && $port =~ /^[0-9]+$/ && $port > 0 && $port < 65536;

  my $ips_known = $self->want_feature('ocfp') || do {
    my $ips = scalar($env->lookup('params.ips', undef));
    ref($ips) eq 'ARRAY' && @$ips;
  };
  info(
    "  #Y{[note]} params.ips is not set, so the API certificate names 127.0.0.1 " .
    "but not the node's address.  The probe dials 127.0.0.1, and clients that " .
    "verify the certificate by IP address will refuse it until params.ips lists it."
  ) unless $ips_known;

  for my $target (@targets) {
    my $host = $ips_known ? $target->{ip} : undef;
    info("  #Y{[note]} no address is known for #C{%s}, so its probe dials 127.0.0.1", $target->{name})
      if $ips_known && !defined($host);
    $self->_probe_node($target->{name}, $port, $host);
  }

  info("");
  info(
    "For deployment details, run:\n".
    "  #G{genesis info $ENV{GENESIS_ENVIRONMENT}}\n"
  );

  return $self->done(1);
}
# }}}

# _rustfs_instances - every rustfs instance and its address, from BOSH {{{
# Returns a list of {name, ip} hashes, or an empty list when BOSH cannot be
# asked, so the caller can fall back to the exodus data.  Errand VMs are
# skipped.  ip is the first address BOSH lists, or undef when it lists none.
sub _rustfs_instances {
  my ($self) = @_;
  my ($out, $rc) = eval {
    $self->env->bosh->execute(
      { stderr => 0, deployment => $self->env->deployment_name },
      'instances', '--json',
    );
  };
  return () if $@ || !defined($rc) || $rc != 0 || !defined($out);

  my $json = eval { JSON::PP->new->decode($out) };
  return () unless ref($json) eq 'HASH' && ref($json->{Tables}) eq 'ARRAY';

  my @targets;
  for my $row (map {@{$_->{Rows} // []}} grep {ref($_) eq 'HASH'} @{$json->{Tables}}) {
    next unless ref($row) eq 'HASH';
    my $instance = $row->{instance} // '';
    next unless $instance =~ m{^rustfs/};
    $instance =~ s/\s*\(.*\)\s*$//;  # drop a "(bootstrap)" style suffix
    my ($ip) = grep {$_ ne ''} split(/[\s,]+/, $row->{ips} // '');
    push @targets, {name => $instance, ip => $ip};
  }
  return @targets;
}
# }}}

# _probe_command - the shell command that probes one node {{{
# It prints exactly one RUSTFS_PROBE= marker line:
#
#   verified         /health/ready answered, and the certificate verified
#                    against the kit CA on the node
#   unverified:cert  /health/ready answered, but the certificate did not
#                    verify against the kit CA
#   unverified:noca  /health/ready answered, but the kit CA could not be
#                    read on the node, so nothing was verified
#   failed:N         curl exited N
#
# The remote command always exits 0 after it prints the marker, so a
# non-zero exit from bosh ssh means the probe never ran.  The marker is
# assembled at run time, so the command text itself never matches it.  The
# job's files are readable by root only, so the verified probe runs curl
# under sudo.
#
# host is the address to dial, 127.0.0.1 when it is undef.  An IPv6 address
# is bracketed, and curl runs with -g so that it reads the brackets as part
# of the address.
sub _probe_command {
  my ($class, $port, $host) = @_;
  $host = '127.0.0.1' unless defined($host) && $host ne '';
  $host = "[$host]" if $host =~ /:/ && $host !~ /^\[/;
  my $url = "https://$host:$port/health/ready";
  my $ca  = CA_FILE;
  return join('; ',
    'p=RUSTFS',
    "url=$url",
    "ca=$ca",
    'if sudo -n grep -q "BEGIN CERTIFICATE" "$ca" 2>/dev/null; then ' .
      'sudo -n curl -g -fsS --max-time 5 -o /dev/null --cacert "$ca" "$url"; rc=$?; why=cert; ' .
    'else rc=60; why=noca; fi',
    # 77 means curl could not read the CA file.
    'if [ "$rc" -eq 77 ]; then rc=60; why=noca; fi',
    'if [ "$rc" -eq 0 ]; then echo "${p}_PROBE=verified"; exit 0; fi',
    # 60 is curl's code for a certificate it could not verify.  Anything
    # else is a real failure that skipping verification would not change.
    'if [ "$rc" -ne 60 ]; then echo "${p}_PROBE=failed:$rc"; exit 0; fi',
    'curl -g -fsSk --max-time 5 -o /dev/null "$url"; rc=$?',
    'if [ "$rc" -eq 0 ]; then echo "${p}_PROBE=unverified:$why"; else echo "${p}_PROBE=failed:$rc"; fi',
    'exit 0',
  );
}
# }}}

# _probe_node - probe the health endpoint of one rustfs instance {{{
sub _probe_node {
  my ($self, $target, $port, $host) = @_;

  info("  Probing health of #C{$target} at #C{%s}...", defined($host) ? $host : '127.0.0.1');

  # Route through $self->env->bosh->execute rather than a bare `bosh -e
  # <alias>`, because execute() sets BOSH_ENVIRONMENT to the director URL
  # along with the CA and client credentials.
  my ($out, $rc) = eval {
    $self->env->bosh->execute(
      { stderr => 0, deployment => $self->env->deployment_name },
      'ssh', $target,
      '--command', ref($self)->_probe_command($port, $host),
      '--results',
    );
  };
  if ($@ || !defined($rc) || $rc != 0) {
    info(
      "    #Y{[warn]} could not run the health probe on $target (%s)",
      $@ ? 'bosh ssh failed' : 'exit '.($rc // 'unknown')
    );
    return 'error';
  }

  my ($result) = ($out // '') =~ /RUSTFS_PROBE=(verified|unverified:(?:cert|noca)|failed:\d+)/;
  if (!defined($result)) {
    info("    #Y{[warn]} $target health probe printed no result");
    return 'error';
  } elsif ($result eq 'verified') {
    info("    #g{[ok]} $target is ready, and its certificate verified against the kit CA");
  } elsif ($result eq 'unverified:cert') {
    info(
      "    #Y{[warn]} $target is ready, but its certificate did not verify against ".
      "the kit CA for that address - rotate #C{certs/api} and redeploy"
    );
  } elsif ($result eq 'unverified:noca') {
    info(
      "    #Y{[warn]} $target is ready, but the kit CA could not be read on the ".
      "node, so its certificate was not verified"
    );
  } else {
    my ($code) = $result =~ /^failed:(\d+)$/;
    info(
      "    #Y{[warn]} $target health probe failed (curl exit $code) - ".
      "cluster may still be converging"
    );
  }
  return $result;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
