package Genesis::Hook::Blueprint::RustFS v0.1.0;

use v5.20;
use warnings; # Genesis min perl version is 5.20

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Blueprint);

use Genesis qw/bail info warning error mkfile_or_fail count_nouns/;
use Socket qw/inet_pton AF_INET AF_INET6/;

# The number of meta.api_cert_ips slots that kit.yml names in the API
# certificate.  Keep the two in step.
use constant API_CERT_IP_SLOTS => 16;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0');
	return $obj;
}

sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	$self->add_files(
		'manifests/rustfs.yml',
		'manifests/releases/rustfs.yml',
		'manifests/releases/bpm.yml',
	);

	my $iaas = $self->iaas;
	my $ips  = scalar($self->env->lookup('params.ips', []));

	# Every static IP the blueprint assigns, which the API certificate names.
	my @cert_ips = ();

	# The node count, once the blueprint knows it.
	my $node_count;

	# Track which optional releases have been added to avoid duplicates
	my %added_releases;

	my $dynamic_static_fragment = '';
	if ($self->want_feature('ocfp')) {
		$self->_refuse_ocfp_overrides;

		# Determine instance count and IPs from ocfp config
		my $subnets = $self->env->ocfp_config_lookup('net.subnets');
		my $prefix   = $self->env->ocfp_subnet_prefix;
		my $az_map   = $self->env->director_exodus_lookup('/network')->{azs};

		my (@ips, @azs) = ();
		# Dedicated static IP for the smoke-tests errand, taken from instance 0's
		# subnet. The "rustfs_ip" substring makes the cloud-config reserved-ips
		# regex fold it into net-rustfs's static range alongside rustfs_ip, so the
		# errand gets a conflict-free static address without a dynamic pool.
		my $smoke_ip;
		for my $subnet (sort grep {/^$prefix/} keys %$subnets) {
			my $ip = $subnets->{$subnet}{'reserved-ips'}{'rustfs_ip'};
			next unless $ip;
			push @ips, $ip;
			$smoke_ip //= $subnets->{$subnet}{'reserved-ips'}{'rustfs_ip_smoke'};

			my $az = $subnets->{$subnet}{az};
			if (!$az) {
				warning("No AZ found for subnet %s", $subnet);
				push @azs, undef;
			} else {
				push @azs, $az_map->{$az}{name} || undef;
			}
		}

		my $requested = scalar($self->env->lookup('params.ocfp_instances', undef));
		bail(
			"#c{params.ocfp_instances} must be a whole number of RustFS nodes, not %s.",
			ref($requested) ? 'a '.lc(ref($requested)) : "'$requested'"
		) if defined($requested) && (ref($requested) || $requested !~ /^[1-9][0-9]*$/);
		my $instances = $requested || scalar(@ips);
		bail("No ocfp subnet reserves a #c{rustfs_ip} address, so there is nowhere to put a RustFS node.") unless $instances;
		bail(
			"Only %s instances available under OCFP; environment requested %s",
			scalar(@ips), $instances
		) if $instances > scalar(@ips);

		@ips = @ips[0..$instances-1];
		@azs = @azs[0..$instances-1];
		my $network_name = "$ENV{GENESIS_ENVIRONMENT}.$ENV{GENESIS_TYPE}.net-rustfs";

		my @valid_azs = grep { defined $_ } @azs;
		bail("No valid availability zones found for RustFS instances") unless @valid_azs;

		# Deduped AZ names for the top-level azs: block (below).
		my %seen_az;
		my @uniq_azs = grep { !$seen_az{$_}++ } @valid_azs;

		# Each AZ carries the environment's CPI so the deploy-time stemcell
		# check matches the right (named) CPI's stemcells; fall back to a bare
		# name when the env has no distinct CPI.
		my $cpi_name = $self->env->cpi_name;
		my $az_block = join '', map {
			"\n- name: $_" . (defined $cpi_name ? "\n  cpi: $cpi_name" : '')
		} @uniq_azs;

		# Top-level azs: lets the deploy-time AZ check resolve the instance
		# group's AZs (genesis reads the unmerged manifest, which otherwise has
		# no azs); genesis prunes this block before bosh deploy.
		#
		# azs (instance group): the base manifest value is a (( grab )) scalar
		# operator, so a literal array overwrites it cleanly — no replace
		# directive (a leading (( replace )) would survive as a literal AZ,
		# since there is no base array to replace).
		#
		# networks: the base manifest value is a literal array, so a leading
		# (( replace )) correctly discards it and pins the ocfp network + static
		# IPs (mirrors the shield ocfp manifest).
		# cluster.yml publishes cluster and cluster_size only when the cluster
		# feature is on, but under ocfp the reservations decide the node
		# count, so the fragment publishes both itself.
		@cert_ips   = @ips;
		$node_count = $instances;
		my $is_cluster = $instances > 1 ? 'true' : 'false';
		$dynamic_static_fragment = <<"EOF";
exodus:
  ips: ${\(join ',', @ips)}
  cluster: $is_cluster
  cluster_size: $instances

azs:$az_block

instance_groups:
- name: rustfs
  azs:${\(join "\n  - ", '', @valid_azs)}
  instances: $instances
  networks:
  - (( replace ))
  - name: $network_name
    static_ips:${\(join "\n    - ", '', @ips)}
EOF

		# Pin the errand to its dedicated static IP on net-rustfs when one is
		# reserved; otherwise the errand falls back to the manifest default
		# (a dynamic address, if the network has spare capacity).
		if ($smoke_ip) {
			# Replace the errand's grab-derived network (the base entry's name is
			# an unresolved (( grab )) at merge time, so spruce would otherwise
			# append rather than merge) and pin it to net-rustfs + the smoke IP.
			$dynamic_static_fragment .= <<"EOF";
- name: smoke-tests
  networks:
  - (( replace ))
  - name: $network_name
    static_ips:
    - $smoke_ip
EOF
		}

	} elsif (ref($ips) ne 'ARRAY') {
		bail("#c{params.ips} must be a list of IP addresses, one per RustFS instance.");

	} elsif (my $instances = scalar(@$ips)) {
		my $requested = scalar($self->env->lookup('params.instances', undef));
		bail(
			"#c{params.ips} lists %d addresses, but #c{params.instances} asks for %s " .
			"nodes.  The kit deploys one node per address in #c{params.ips}, so " .
			"remove #c{params.instances} or make the two agree.",
			$instances, ref($requested) ? 'a '.lc(ref($requested)).' of' : $requested
		) if defined($requested) && (ref($requested) || $requested !~ /^\s*\d+\s*$/ || $requested != $instances);

		@cert_ips   = @$ips;
		$node_count = $instances;
		$dynamic_static_fragment = <<"EOF";
exodus:
  ips: ${\(join ',', @$ips)}

instance_groups:
- name: rustfs
  instances: $instances
  networks:
  - name: (( grab params.rustfs_network || "rustfs" ))
    static_ips:${\(join "\n    - ", '', @$ips)}
EOF
	}

	$self->add_files('manifests/azure.yml')   if $iaas eq 'azure';
	$self->add_files('manifests/stackit.yml') if $iaas eq 'stackit';

	my @invalid = ();
	for my $feature ($self->features) {
		if ($feature eq 'ocfp') {
			$self->add_files('manifests/ocfp.yml');

		} elsif ($feature eq 'route-registrar') {
			$self->add_files('manifests/route-registrar.yml');
			unless ($added_releases{'routing'}++) {
				$self->add_files('manifests/releases/routing.yml');
			}
			unless ($added_releases{'bosh-dns-aliases'}++) {
				$self->add_files('manifests/releases/bosh-dns-aliases.yml');
			}

		} elsif ($feature eq 'cluster') {
			$self->add_files('manifests/cluster.yml');

		} elsif ($feature =~ /^scale-(small|medium|large)$/) {
			$self->add_files("manifests/scale-${1}.yml");

		} elsif ($feature =~ /^upgrade-(serial|all-at-once)$/) {
			$self->add_files("manifests/upgrade-${1}.yml");

		} elsif ($feature eq 'resolute') {
			# Handled after the loop so that it overrides every other fragment.

		} elsif (-f "$ENV{GENESIS_ROOT}/${feature}.yml") {
			$self->add_files("$ENV{GENESIS_ROOT}/${feature}.yml");

		} else {
			push @invalid, $feature;
		}
	}

	unless (defined($node_count)) {
		my $requested = scalar($self->env->lookup(
			'params.instances', $self->want_feature('cluster') ? 3 : 1
		));
		$node_count = $requested
			if defined($requested) && !ref($requested) && $requested =~ /^\s*\d+\s*$/;
	}
	$self->_refuse_two_nodes($node_count);
	$self->_check_cluster_addresses(scalar(@cert_ips));
	$dynamic_static_fragment .= $self->_api_cert_ips_fragment(@cert_ips)
		if @cert_ips;

	# The static IP fragment goes after every feature fragment.  cluster.yml
	# sets its own static_ips, and when it came later it replaced params.ips
	# and, under ocfp, appended a second network to the instance group.
	if ($dynamic_static_fragment) {
		my $statics_file = "manifests/network.dynamic.yml";
		mkfile_or_fail($self->env->kit->path($statics_file), 0644, $dynamic_static_fragment);
		$self->add_files($statics_file);
	}

	$self->_process_resolute;

	bail(
		"Invalid %s encountered: %s",
		count_nouns(scalar(@invalid), 'feature', suppress_count => 1),
		join(', ', @invalid)
	) if @invalid;

	return $self->done(1);
}

# _api_cert_ips_fragment - meta.api_cert_ips for the API certificate names {{{
# kit.yml names the API certificate after meta.api_cert_ips, one maybe: slot
# per address, because Genesis dereferences kit metadata as scalars.  The
# list is written only from addresses the blueprint knows before the cloud
# config is merged, since `genesis add-secrets` and `check-secrets` build the
# certificate names without downloading it.
sub _api_cert_ips_fragment {
	my ($self, @ips) = @_;

	my @invalid = grep {!_is_ip_address($_)} @ips;
	bail(
		"The RustFS API certificate names every static IP address, so each " .
		"address in #c{params.ips} or the ocfp #c{rustfs_ip} reservations " .
		"must be a single IPv4 or IPv6 address.  These are not: %s",
		join(', ', map {defined($_) ? (ref($_) ? 'a '.lc(ref($_)) : "'$_'") : 'null'} @invalid)
	) if @invalid;

	bail(
		"The RustFS API certificate can name at most %d static IP addresses, " .
		"but this environment assigns %d.  Deploy at most %d instances.",
		API_CERT_IP_SLOTS, scalar(@ips), API_CERT_IP_SLOTS
	) if @ips > API_CERT_IP_SLOTS;

	# meta.url_host is the first node's address as it sits in a URL, so the
	# exodus URLs bracket an IPv6 address.  Without a known list, rustfs.yml
	# falls back to the first static IP that BOSH assigns.
	my $url_host = $ips[0] =~ /:/ ? "[$ips[0]]" : $ips[0];

	return "\nmeta:\n  url_host: \"$url_host\"\n  api_cert_ips:" . join('', map {"\n  - $_"} @ips) . "\n";
}
# }}}

# _refuse_ocfp_overrides - refuse node settings that ocfp replaces {{{
# Under ocfp the rustfs_ip reservations decide the addresses, and
# params.ocfp_instances decides how many of them to use.  The ocfp fragment
# replaces params.ips and params.instances, so a value there would be
# silently ignored.
sub _refuse_ocfp_overrides {
	my ($self) = @_;
	for my $param (qw/ips instances/) {
		my $value = scalar($self->env->lookup("params.$param", undef));
		next unless defined($value);
		bail(
			"The #c{ocfp} feature takes the RustFS node addresses from the ocfp " .
			"#c{rustfs_ip} reservations, so it ignores params.%s.  Remove " .
			"#c{params.%s}, and set #c{params.ocfp_instances} to choose how many " .
			"of the reserved addresses to use.",
			$param, $param
		);
	}
	return;
}
# }}}

# _refuse_two_nodes - refuse a two-node cluster {{{
# RustFS splits each object into data and parity shards across every drive.
# When the two counts are equal, as they are on two nodes, a write needs
# more than half of the drives.  With two nodes, losing either one stops
# writes, so a two-node cluster is less available than a single node and
# doubles the hardware.  Three nodes is the smallest cluster that keeps
# writing through the loss of one node.
sub _refuse_two_nodes {
	my ($self, $count) = @_;
	return unless defined($count) && $count == 2;
	bail(
		"The RustFS kit refuses to deploy exactly two nodes.  A two-node cluster stops " .
		"writing when either node is down, so it is less available than one " .
		"node.  Deploy one node, or a cluster of three or more."
	);
}
# }}}

# _check_cluster_addresses - refuse a cluster whose addresses are unknown {{{
# Without params.ips or ocfp, BOSH picks the static IPs from the cloud
# config's range at deploy time.  Genesis generates the API certificate
# before that, so the certificate could not name the peers, and every peer
# handshake would fail.  A single node never dials a peer, so it may still
# take its address from the cloud config.
sub _check_cluster_addresses {
	my ($self, $known_ips) = @_;
	return if $known_ips;

	my $default   = $self->want_feature('cluster') ? 3 : 1;
	my $instances = scalar($self->env->lookup('params.instances', $default));
	return unless defined($instances) && !ref($instances)
		&& $instances =~ /^\s*\d+\s*$/ && $instances > 1;

	bail(
		"A RustFS cluster needs #c{params.ips} to list the static IP address of " .
		"every node, or the #c{ocfp} feature to supply them.  Peers verify each " .
		"other's API certificate by IP address, and Genesis generates that " .
		"certificate before BOSH assigns addresses from the cloud config, so " .
		"without the list the peers cannot form a cluster."
	);
}
# }}}

# _is_ip_address - true for a single IPv4 or IPv6 address {{{
# inet_pton accepts exactly one address in the standard text forms, so it
# refuses BOSH ranges such as "10.0.0.10-10.0.0.12" and CIDR blocks.
sub _is_ip_address {
	my ($ip) = @_;
	return 0 unless defined($ip) && !ref($ip) && $ip ne '';
	return 1 if defined(inet_pton(AF_INET, $ip));
	return 1 if $ip =~ /:/ && defined(inet_pton(AF_INET6, $ip));
	return 0;
}
# }}}

# _process_resolute - Opt-in ubuntu-resolute stemcell support {{{
# Called after every other fragment is added so that it overrides the
# stemcell os default (ubuntu-noble) and the bpm release pin.
sub _process_resolute {
	my ($self) = @_;

	if ($self->want_feature('resolute')) {
		my $stemcell_os = scalar($self->env->lookup('params.stemcell_os', 'ubuntu-resolute'));
		bail(
			"The #c{resolute} feature sets the stemcell os to ubuntu-resolute, but " .
			"the environment sets #c{params.stemcell_os} to #R{%s}.  " .
			"Remove that parameter.", $stemcell_os
		) if $stemcell_os ne 'ubuntu-resolute';
		$self->add_files(
			'manifests/resolute.yml',
			# bpm releases older than 1.4.41 do not compile on resolute.
			'manifests/releases/bpm-resolute.yml',
		);
	} elsif (scalar($self->env->lookup('params.stemcell_os', 'ubuntu-noble')) eq 'ubuntu-resolute') {
		bail(
			"The environment sets #c{params.stemcell_os} to ubuntu-resolute " .
			"without the #c{resolute} feature.  Enable the feature and remove " .
			"that parameter."
		);
	}
	return;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
