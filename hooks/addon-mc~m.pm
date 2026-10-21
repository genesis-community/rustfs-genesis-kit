package Genesis::Hook::Addon::RustFS::Mc v0.2.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);
use Genesis qw/info bail/;

use File::Path qw/make_path/;
use IPC::Open3 qw/open3/;
use Symbol qw/gensym/;

# init - Initialize the hook {{{
sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
  $obj->check_minimum_genesis_version('3.1.0');
  return $obj;
}
# }}}

# cmd_details - Short description shown in genesis do --list {{{
sub cmd_details {
  return
    "Configure an mc (MinIO client) alias for the cluster, trusting the kit CA.\n".
    "The secret key goes to mc on stdin and is never printed.\n".
    "Requires mc on the PATH (https://min.io/docs/minio/linux/reference/minio-mc.html).";
}
# }}}

# perform - Main hook execution {{{
sub perform {
  my ($self) = @_;
  return 1 if $self->completed;

  my $env      = $self->env;
  my $env_name = $env->name;

  my $s3_api_url = $env->exodus_lookup('s3_api_url', undef);
  bail(
    "Could not read s3_api_url from the exodus data of %s.\n".
    "Deploy the environment at least once first.",
    $env_name
  ) unless $s3_api_url;

  my $access_key = $env->exodus_lookup('access_key', undef);
  bail("Could not read access_key from the exodus data of %s.", $env_name)
    unless $access_key;

  my $ca = $env->exodus_lookup('ca', undef);

  my $alias = "rustfs-$env_name";
  $alias =~ s/[^A-Za-z0-9_-]/-/g;

  my $creds_path = $env->secrets_base . 'credentials';
  my $mc = _find_mc();
  bail(
    "mc is not on the PATH, so the alias cannot be configured.\n".
    "Install mc and run this addon again, or configure the alias by hand\n".
    "with the secret on stdin, so that it never reaches a command line:\n\n".
    "  printf '%%s\\n%%s\\n' %s \"\$(safe -T %s get %s:secret_key)\" \\\n".
    "    | mc alias set %s %s",
    $access_key, $env->vault->name, $creds_path, $alias, $s3_api_url
  ) unless $mc;

  # The secret is not in exodus, so read it from the environment's vault.
  my $secret_key = $env->vault->get($creds_path, 'secret_key');
  bail(
    "Could not read secret_key from %s.\n".
    "Check that you are authenticated: safe -T %s auth",
    $creds_path, $env->vault->name
  ) unless defined($secret_key) && $secret_key ne '';
  chomp $secret_key;

  # mc trusts every certificate in its CAs directory, so installing the kit
  # CA there lets every mc command verify the API without --insecure.
  my @insecure;
  if ($s3_api_url =~ m{^https://}) {
    if (defined($ca) && $ca =~ /BEGIN CERTIFICATE/) {
      my $ca_file = _install_ca($alias, $ca);
      info("Installed the kit CA for %s at #C{%s}", $alias, $ca_file);
    } else {
      @insecure = ('--insecure');
      info("#Y{Warning}: exodus holds no CA, so the alias skips certificate verification.");
    }
  }

  # With no keys on the command line and stdin not a terminal, mc reads the
  # access key and then the secret key from stdin, one per line.
  my ($status, $output) = _run_with_stdin(
    "$access_key\n$secret_key\n",
    $mc, 'alias', 'set', @insecure, $alias, $s3_api_url
  );
  $output =~ s/\Q$secret_key\E/<redacted>/g;
  bail(
    "mc alias set %s %s failed (exit %d):\n%s",
    $alias, $s3_api_url, $status, $output
  ) if $status != 0;

  info("");
  info("#M{RustFS mc alias for environment: %s}", $env_name);
  info("");
  info("mc now has the alias #C{%s} for %s, with access key %s.", $alias, $s3_api_url, $access_key);
  info("The secret key was passed to mc on stdin and is stored in mc's own config.");
  info("");
  info("Common mc commands:");
  info("");
  info("  List buckets:                #G{mc %sls %s}",                         _flags(@insecure), $alias);
  info("  Create a bucket:             #G{mc %smb %s/<bucket-name>}",           _flags(@insecure), $alias);
  info("  Upload a file:               #G{mc %scp <local-file> %s/<bucket-name>/}", _flags(@insecure), $alias);
  info("  Download a file:             #G{mc %scp %s/<bucket-name>/<file> <local-dest>}", _flags(@insecure), $alias);
  info("  Remove a bucket (recursive): #G{mc %srb --force %s/<bucket-name>}",   _flags(@insecure), $alias);
  info("  Show space used per bucket:  #G{mc %sdu --depth 2 %s}",               _flags(@insecure), $alias);
  info("");
  info("Remove the alias with #G{mc alias remove %s}.", $alias);
  info("");

  return $self->done(1);
}
# }}}

# _flags - the global flags every printed mc command needs {{{
sub _flags { @_ ? join(' ', @_).' ' : '' }
# }}}

# _find_mc - the mc binary on the PATH, as mc or as mcli {{{
sub _find_mc {
  for my $name (qw/mc mcli/) {
    for my $dir (split /:/, $ENV{PATH} // '') {
      next unless length $dir;
      my $path = "$dir/$name";
      return $path if -f $path && -x _;
    }
  }
  return undef;
}
# }}}

# _install_ca - write the kit CA into mc's CAs directory {{{
sub _install_ca {
  my ($alias, $ca) = @_;
  my $dir = "$ENV{HOME}/.mc/certs/CAs";
  make_path($dir, {mode => 0700}) unless -d $dir;
  my $file = "$dir/$alias.crt";
  open(my $fh, '>', $file) or bail("Could not write %s: %s", $file, $!);
  print $fh $ca;
  print $fh "\n" unless $ca =~ /\n\z/;
  close($fh) or bail("Could not write %s: %s", $file, $!);
  chmod(0644, $file);
  return $file;
}
# }}}

# _run_with_stdin - run a command without a shell, feed it stdin, and return {{{
# its exit status and its combined stdout and stderr.
sub _run_with_stdin {
  my ($input, @cmd) = @_;
  my ($in, $out) = (undef, gensym);
  my $pid = eval { open3($in, $out, undef, @cmd) };
  bail("Could not run %s: %s", $cmd[0], $@ // 'unknown error') unless $pid;
  {
    local $SIG{PIPE} = 'IGNORE';
    print $in $input;
    close($in);
  }
  my $output = do { local $/; <$out> } // '';
  close($out);
  waitpid($pid, 0);
  return ($? >> 8, $output);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
