package Genesis::Hook::Addon::RustFS v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {
  push @INC,
    $ENV{GENESIS_LIB}
      ? $ENV{GENESIS_LIB}
      : $ENV{HOME}.'/.genesis/lib'
}

use parent qw(Genesis::Hook::Addon);
use Genesis qw/bail/;

# valid_addons - List of supported addon names and their shortcut letters {{{
# Supported addons:
#   smoke             (s) - run smoke-tests BOSH errand
#   reset-credentials (r) - regenerate access_key + secret_key in Vault
#   mc                (m) - print mc alias + common commands for the cluster
#   info              (i) - show exodus data (URLs, access key)
my %SHORTCUTS = (
  s => 'smoke',
  r => 'reset-credentials',
  m => 'mc',
  i => 'info',
);
# }}}

# init - enforce a minimum Genesis version {{{
sub init {
  my ($class, %ops) = @_;
  my $self = $class->SUPER::init(%ops);
  $self->check_minimum_genesis_version('3.1.0');
  return $self;
}
# }}}

# valid_addons - return the list of supported addon command names {{{
sub valid_addons {
  return qw/smoke reset-credentials mc info/;
}
# }}}

# addon_name_for - resolve a shortcut letter or full name to canonical addon name {{{
sub addon_name_for {
  my ($self, $cmd) = @_;
  return $SHORTCUTS{$cmd} if exists $SHORTCUTS{$cmd};
  return $cmd;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
