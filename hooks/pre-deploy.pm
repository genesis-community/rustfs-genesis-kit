package Genesis::Hook::PreDeploy::RustFS v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail info warning run load_json new_enough semver/;
use JSON::PP;
use Socket qw/inet_pton AF_INET AF_INET6/;

# bpm releases older than this do not compile on the resolute stemcell,
# because their tini package needs an older CMake than resolute ships.
my $RESOLUTE_MIN_BPM = '1.4.41';

# bpm 1.4.31 cannot start any process on a cgroup v2 stemcell, which noble
# is.  "latest" or no version at all lets the director pick it.
my %NOBLE_BAD_BPM = ('1.4.31' => 1);

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

  my $env  = $self->env;
  my $name = $env->name;

  my $manifest = $self->_manifest;
  if ($self->want_feature('resolute')) {
    $self->_check_resolute($manifest);
  } else {
    $self->_check_noble_bpm($manifest);
  }
  $self->_check_api_cert($manifest);
  $self->_check_node_count($manifest);

  info("");
  info("#M{$name} - RustFS pre-deploy");
  info("  target:     #C{%s}", $name);
  info("  deployment: #C{%s}", $env->deployment_name);
  info("");
  info("Genesis manages credentials - no pre-deploy credential checks needed.");
  info("");

  return $self->done(1);
}
# }}}

# _manifest - the merged manifest that Genesis is about to deploy {{{
# The pre-deploy checks read the merged manifest, because it is the last
# word on what BOSH deploys.
sub _manifest {
  my ($self) = @_;

  my $file = $ENV{GENESIS_MANIFEST_FILE};
  bail(
    "Genesis did not pass the manifest to the RustFS pre-deploy hook, so " .
    "its stemcells, releases, and node count cannot be checked."
  ) unless defined($file) && -f $file && -r $file;

  # The manifest holds secrets, so its conversion is redacted from the
  # trace log.
  my ($out, $rc, $err) = run({stderr => 0, redact_output => 1}, 'spruce json < "$1"', $file);
  my $manifest = $rc == 0 ? eval {load_json($out)} : undef;
  bail(
    "The manifest at #C{%s} could not be read for the RustFS pre-deploy " .
    "checks: %s",
    $file, ($err // '') =~ s/\s+$//r || "spruce exited $rc"
  ) unless ref($manifest) eq 'HASH';
  return $manifest;
}
# }}}

# _check_resolute - the merged manifest really deploys resolute {{{
# The blueprint gate reads params.stemcell_os only, so an environment file
# or a custom feature fragment can still set its own stemcells or override
# the bpm release.  The merged manifest is the last word, so we check it.
# Every stemcell must be ubuntu-resolute, and bpm must be 1.4.41 or newer.
sub _check_resolute {
  my ($self, $manifest) = @_;
  $manifest //= $self->_manifest;

  my $stemcells = $manifest->{stemcells};
  bail(
    "The #c{resolute} feature is enabled, but the manifest lists no stemcells."
  ) unless ref($stemcells) eq 'ARRAY' && @$stemcells;

  my @wrong = map {
    ref($_) eq 'HASH'
      ? sprintf("%s (#R{%s})", $_->{alias} // '?', $_->{os} // 'no os')
      : '#R{an entry that is not a stemcell}'
  } grep {
    ref($_) ne 'HASH' || ($_->{os} // '') ne 'ubuntu-resolute'
  } @$stemcells;
  bail(
    "The #c{resolute} feature is enabled, but the manifest deploys these " .
    "stemcells on another OS: %s.  Remove the override that sets them.",
    join(', ', @wrong)
  ) if @wrong;

  my @bpm = grep {ref($_) eq 'HASH' && ($_->{name} // '') eq 'bpm'}
    @{ref($manifest->{releases}) eq 'ARRAY' ? $manifest->{releases} : []};
  bail(
    "The #c{resolute} feature is enabled, but the manifest deploys no bpm " .
    "release, and the rustfs-server job needs bpm %s or newer on resolute.",
    $RESOLUTE_MIN_BPM
  ) unless @bpm;
  for my $release (@bpm) {
    my $version = $release->{version} // '';
    bail(
      "The manifest deploys bpm #R{%s} on a resolute stemcell, which needs " .
      "bpm %s or newer.  Remove the override that pins bpm, so that the " .
      "#c{resolute} feature can choose it.",
      $version eq '' ? 'without a version' : $version, $RESOLUTE_MIN_BPM
    ) unless $version ne 'latest' && semver($version) && new_enough($version, $RESOLUTE_MIN_BPM);
  }
  return 1;
}
# }}}

# _check_noble_bpm - refuse a bpm that cannot start processes on noble {{{
# The kit pins bpm 1.4.22 for noble, but an environment file can override
# the pin.  bpm 1.4.31 starts no process on a cgroup v2 stemcell, and
# "latest" or a missing version lets the director choose whatever bpm it
# holds, which may be 1.4.31.
sub _check_noble_bpm {
  my ($self, $manifest) = @_;

  my @bpm = grep {ref($_) eq 'HASH' && ($_->{name} // '') eq 'bpm'}
    @{ref($manifest->{releases}) eq 'ARRAY' ? $manifest->{releases} : []};
  for my $release (@bpm) {
    my $version = $release->{version} // '';
    my $why = $version eq ''         ? 'without a version, so the director picks one'
            : $version eq 'latest'   ? 'as latest, so the director picks one'
            : $NOBLE_BAD_BPM{$version} ? "at $version, which cannot start processes on cgroup v2"
            : undef;
    next unless $why;
    bail(
      "The manifest deploys bpm %s.  bpm 1.4.31 starts no process on the " .
      "ubuntu-noble stemcell, so the RustFS nodes would never come up.  " .
      "Remove the override that pins bpm, so that the kit's pin applies, or " .
      "pin a version other than 1.4.31.",
      $why
    );
  }
  return 1;
}
# }}}

# _check_api_cert - the API certificate names every node address {{{
# Peers dial each other by IP address and verify the API certificate, so
# it must name every address in meta.api_cert_ips.  `genesis add-secrets`
# does not touch a certificate that already exists, so a certificate made
# before params.ips or the ocfp reservations changed still carries the old
# list.  Deploying with it partitions the cluster, so we refuse.  Only the
# public certificate is read, never the key.
sub _check_api_cert {
  my ($self, $manifest) = @_;
  my $env = $self->env;

  # meta is pruned from the manifest that Genesis hands the hook, so the
  # addresses come from the unpruned base manifest.
  my $want = eval {scalar($env->manifest_lookup('meta.api_cert_ips', []))};
  $want = ref($manifest) eq 'HASH' && ref($manifest->{meta}) eq 'HASH'
    ? $manifest->{meta}{api_cert_ips} : []
    unless defined($want);
  my @want = ('127.0.0.1', ref($want) eq 'ARRAY' ? grep {defined($_) && !ref($_)} @$want : ());

  my $path = $env->secrets_base . 'certs/api';
  my $cert = $env->vault->get($path, 'certificate');
  bail(
    "The RustFS API certificate at #C{%s} could not be read.  Run " .
    "#G{genesis %s add-secrets} to generate it.",
    $path, $env->name
  ) unless defined($cert) && $cert =~ /BEGIN CERTIFICATE/;

  my %have = map {$_ => 1} _cert_ip_names($cert);
  bail(
    "The RustFS API certificate at #C{%s} could not be parsed to check the " .
    "addresses it names.", $path
  ) unless %have;

  my @missing = grep {my $p = _packed_ip($_); !defined($p) || !$have{$p}} @want;
  bail(
    "The RustFS API certificate does not name every node address.  It is " .
    "missing %s.  Peers verify each other's certificate by IP address, so " .
    "the cluster would not form.  Run #G{genesis %s rotate-secrets certs/api} " .
    "to renew it with the current addresses, then deploy again.",
    join(', ', @missing), $env->name
  ) if @missing;

  info("  #g{[ok]} the API certificate names all %d node addresses", scalar(@want) - 1)
    if @want > 1;
  return 1;
}
# }}}

# _cert_ip_names - the IP subject alternative names of a certificate {{{
# Returns each address in packed form, so that IPv6 spellings compare
# equal.  The certificate is public, so it may sit on the command line.
sub _cert_ip_names {
  my ($cert) = @_;
  my ($out, $rc) = run(
    {stderr => '/dev/null'},
    'printf "%s\n" "$1" | openssl x509 -noout -text', $cert
  );
  return () unless $rc == 0 && defined($out);
  my ($san) = $out =~ /X509v3 Subject Alternative Name:[^\n]*\n\s*([^\n]*)/;
  return () unless defined($san);
  return grep {defined} map {_packed_ip($_)} ($san =~ /IP Address:\s*([0-9A-Fa-f:.]+)/g);
}
# }}}

# _packed_ip - an address in packed form, or undef {{{
sub _packed_ip {
  my ($ip) = @_;
  return undef unless defined($ip) && !ref($ip);
  my $p = inet_pton(AF_INET, $ip);
  return "4$p" if defined($p);
  $p = $ip =~ /:/ ? inet_pton(AF_INET6, $ip) : undef;
  return defined($p) ? "6$p" : undef;
}
# }}}

# _check_node_count - refuse a change to the number of nodes {{{
# RustFS fixes its erasure layout the first time a cluster starts.  When the
# node count changes, every node finds a drive layout that does not match
# its volume list and refuses to start, and the cluster stops serving.  A
# single node is worse, because its drive is formatted as single-node
# single-drive, which cannot be expanded at all.  So the deploy stops here
# unless the operator says the change is on purpose.
sub _check_node_count {
  my ($self, $manifest) = @_;
  my $env = $self->env;

  my ($group) = grep {ref($_) eq 'HASH' && ($_->{name} // '') eq 'rustfs'}
    @{ref($manifest->{instance_groups}) eq 'ARRAY' ? $manifest->{instance_groups} : []};
  my $new = ref($group) eq 'HASH' ? $group->{instances} : undef;
  return 1 unless defined($new) && !ref($new) && $new =~ /^[0-9]+$/;

  my ($old, $source) = $self->_deployed_node_count;
  return 1 unless defined($old) && $old != $new;

  bail(
    "This deploy would grow a single RustFS node to %d nodes, and that " .
    "cannot be done in place.  A single node formats its drive as " .
    "single-node single-drive, and RustFS refuses to start with the error " .
    "\"unsupported pool expansion\" in " .
    "/var/vcap/sys/log/rustfs-server/rustfs-server.stderr.log.  To move to " .
    "a cluster, copy the data out with an S3 client, delete the deployment, " .
    "set #c{params.ips} to the addresses of the new nodes, run " .
    "#G{genesis %s rotate-secrets certs/api}, deploy, and copy the data back.",
    $new, $env->name
  ) if $old == 1 && $new > 1;

  my $allowed = scalar($env->lookup('params.allow_node_count_change', 0));
  if ($allowed && $allowed ne 'false') {
    warning(
      "RustFS goes from %d nodes (from %s) to %d, because " .
      "#c{params.allow_node_count_change} is set.  Nodes whose drives hold " .
      "the old layout will refuse to start.",
      $old, $source, $new
    );
    return 1;
  }

  bail(
    "This deploy would change the RustFS node count from %d (from %s) to " .
    "%d.  RustFS fixes its erasure layout when the cluster first starts, so " .
    "the nodes would find drives that do not match the new layout, refuse " .
    "to start, and stop serving data.  To resize, copy the data out with an " .
    "S3 client, delete the deployment, deploy the new size, and copy the " .
    "data back.  Set #c{params.allow_node_count_change} to true only when " .
    "the drives no longer hold data that you need.",
    $old, $source, $new
  );
}
# }}}

# _deployed_node_count - the node count of the running deployment {{{
# Asks BOSH first, and falls back to the exodus data from the last deploy.
# Returns nothing for a first deploy, or when neither source answers.
sub _deployed_node_count {
  my ($self) = @_;
  my $env = $self->env;

  my ($out, $rc, $err) = eval {
    $env->bosh->execute(
      {stderr => 0, deployment => $env->deployment_name},
      'instances', '--json',
    );
  };
  unless ($@) {
    my $text = join("\n", grep {defined} $out, $err);
    return () if $text =~ /doesn't exist|does not exist/;
    if (defined($rc) && $rc == 0) {
      my $json = eval {JSON::PP->new->decode($out)};
      if (ref($json) eq 'HASH' && ref($json->{Tables}) eq 'ARRAY') {
        my $count = grep {
          ref($_) eq 'HASH' && ($_->{instance} // '') =~ m{^rustfs/}
        } map {@{$_->{Rows} // []}} grep {ref($_) eq 'HASH'} @{$json->{Tables}};
        return ($count, 'BOSH') if $count;
      }
    }
  }

  my $count = scalar($env->exodus_lookup('instances', undef));
  return ($count, 'the exodus data')
    if defined($count) && !ref($count) && $count =~ /^[1-9][0-9]*$/;
  return ();
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
