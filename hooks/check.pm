package Genesis::Hook::Check::RustFS v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Check);

use Genesis qw/info warning/;

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
	my $ok = 1;

	$ok = 0 unless $self->check_cloud_config;
	$ok = 0 unless $self->check_route_registrar;

	# Stemcells are left to Genesis core, which checks every stemcell the
	# manifest names on deploy and on `genesis check --stemcells`, and skips
	# them under --no-stemcells.  The kit used to repeat that check here,
	# named only ubuntu-noble, and contacted the director even when the
	# operator had turned stemcell checks off.

	return $self->done($ok);
}
# }}}

# check_cloud_config - The vm type, network, and disk type the manifest uses {{{
sub check_cloud_config {
	my ($self) = @_;
	return 1 unless $ENV{GENESIS_CLOUD_CONFIG};

	$self->start_check('cloud-config');

	# An explicit param always wins, as it does in the manifest.  Without one,
	# the ocfp feature names every entry after the environment and type
	# (manifests/ocfp.yml), and otherwise the manifest defaults apply.
	my %default = (vm_type => 'default', network => 'rustfs', disk_type => 'default');
	if ($self->want_feature('ocfp')) {
		my $cloud = "$ENV{GENESIS_ENVIRONMENT}.$ENV{GENESIS_TYPE}.";
		%default = (
			vm_type   => "${cloud}vm-rustfs",
			network   => "${cloud}net-rustfs",
			disk_type => "${cloud}disk-rustfs",
		);
	}
	my $vm_type   = scalar($self->env->lookup('params.rustfs_vm_type',   $default{vm_type}));
	my $network   = scalar($self->env->lookup('params.rustfs_network',   $default{network}));
	my $disk_type = scalar($self->env->lookup('params.rustfs_disk_type', $default{disk_type}));

	$self->has_entry('cloud-config', 'vm_type',   $vm_type);
	$self->has_entry('cloud-config', 'network',   $network);
	$self->has_entry('cloud-config', 'disk_type', $disk_type);

	# The smoke-tests errand can run on its own vm type.
	my $errand_vm_type = scalar($self->env->lookup('params.errand_vm_type', $vm_type));
	$self->has_entry('cloud-config', 'vm_type', $errand_vm_type)
		if $errand_vm_type ne $vm_type;

	return $self->check_result('cloud-config');
}
# }}}

# check_route_registrar - CF exodus data the route-registrar feature needs {{{
# route-registrar uses NATS mTLS (cert and key), not the older password auth.
sub check_route_registrar {
	my ($self) = @_;
	return 1 unless $self->want_feature('route-registrar');

	$self->start_check('route-registrar');

	# The manifest reads the CF exodus data of the environment with the same
	# name (manifests/route-registrar.yml), so the check reads it from there.
	my @errors;
	my $cf_slug   = $self->env->name . '/cf';
	my $cf_exodus = eval { scalar($self->env->exodus_lookup('.', undef, $cf_slug)) };
	if ($@) {
		push @errors, "could not read CF exodus data: $@";
	} elsif (ref($cf_exodus) ne 'HASH') {
		push @errors, "no CF exodus data under $cf_slug, so deploy CF first";
	} else {
		push @errors, "CF exodus missing system_domain"    unless $cf_exodus->{system_domain};
		push @errors, "CF exodus missing core_network"     unless $cf_exodus->{core_network};
		push @errors, "CF exodus missing nats_client_cert" unless $cf_exodus->{nats_client_cert};
		push @errors, "CF exodus missing nats_client_key"  unless $cf_exodus->{nats_client_key};
	}

	return $self->check_result('route-registrar', 'failed', join('; ', @errors)) if @errors;
	return $self->check_result('route-registrar', 'passed');
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
