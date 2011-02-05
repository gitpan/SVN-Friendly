use strict;
use warnings;
package SVN::Friendly::Repos;
my $CLASS = __PACKAGE__;

#------------------------------------------------------------------
our @ISA=qw(SVN::Repos);

#------------------------------------------------------------------
use SVN::Repos;
use SVN::Fs;        #needed for fs type constants

use SVN::Friendly::Config;
my $CONFIG_CLASS='SVN::Friendly::Config';

#------------------------------------------------------------------

sub START_COMMIT    { \&SVN::Repos::start_commit_hook }
sub PRE_COMMIT      { \&SVN::Repos::pre_commit_hook }
sub PRE_REVPROP     { \&SVN::Repos::pre_revprop_change_hook }
sub POST_REVPROP    { \&SVN::Repos::post_revprop_change_hook }
sub PRE_OBLITERATE  { \&SVN::Repos::pre_obliterate_hook }
sub POST_OBLITERATE { \&SVN::Repos::post_obliterate_hook }
sub PRE_LOCK        { \&SVN::Repos::pre_lock_hook }
sub POST_LOCK       { \&SVN::Repos::post_lock_hook }
sub PRE_UNLOCK      { \&SVN::Repos::pre_unlock_hook }
sub POST_UNLOCK     { \&SVN::Repos::post_unlock_hook }


#------------------------------------------------------------------

my %SINGLETONS;

#------------------------------------------------------------------

use Carp;

#==================================================================
# CLASS METHODS
#==================================================================

#------------------------------------------------------------------

sub create {
  # $sNative - svn_repos_create (called by SVN::Repos) will complain
  #            about non canonical paths if directory paths are
  #            '/' terminated!!!!
  #            If will also barf unless $sNative either is empty or
  #            non-existant.
  # $xConfigFs a hash storing parameters that describe the
  #            repository's file system. See svn_fs_create. Some
  #            of the parameters:
  #            SVN_FS_CONFIG_FS_TYPE => file system type
  #               possible values:      $SVN::Fs::TYPE_FSFS
  #                                     $SVN::Fs::TYPE_BDB
  # $xConfig - opaque structure containing svn_config_t objects;
  #            these objects are created by reading a file or
  #            created in memory with various svn_config_XXX functions
  #            -or-
  #            the name of a directory storing configuration data

  # ignore $sClass - we need it only so we can call this as a class
  # method
  my ($sClass, $sNative, $xConfig, $xConfigFs, $oUuid) = @_;
  $xConfig = $CONFIG_CLASS->new($xConfig);

  if (!ref($xConfigFs)) {
    #config is type of file system rather than a hash reference
    $xConfigFs = $SVN::Fs::TYPE_FSFS unless defined($xConfigFs);
    $xConfigFs = { $SVN::Fs::CONFIG_FS_TYPE => $xConfigFs };
  }

  #print STDERR "root=<$sNative>"
  #  . "\nconfig="
  #  . (defined $xConfig   ? " <@{[%$xConfig]}> "  : '<undef>')
  #  . "\nfsconfig="
  #  . (defined $xConfigFs ? " <@{[%$xConfigFs]}>" : '<undef>')
  #  . "\n";

  #does $sRepoPath need to be a UTF-8 encoded URL or just a OS
  #acceptable file system path?
  my $oRepos = SVN::Repos::create($sNative, undef, undef
                                  , $xConfig->getCategoryHash()
                                  , $xConfigFs);
  $oRepos = $sClass->_new($sNative, $oRepos);

  if (defined($oUuid)) {
    $oRepos->setUUID($oUuid);
  }
  return $oRepos;
}

#------------------------------------------------------------------

sub destroy {
  my ($xRepos) = @_;
  my $sNative = ref($xRepos) ? $xRepos->getRoot() : $xRepos;
  SVN::Repos::delete($sNative);

  # no longer valid, so delete it from list
  delete $SINGLETONS{$sNative};
}

#------------------------------------------------------------------

sub new {
  my ($sClass, $sNative) = @_;
  my $sRef = ref($sNative);
  my $oRepos;

  if ($sRef eq '_p_svn_repos_t') {
    $oRepos = $sNative;
    $sNative = SVN::Repos::path($oRepos);
  } elsif ($sRef && $sRef->isa(__PACKAGE__)) {
    return $sNative; #already have an object
  }

  my $k="$sClass($sNative)";
  if (!exists($SINGLETONS{$k})) {
    $oRepos = SVN::Repos::open($sNative) unless defined($oRepos);
    return $sClass->_new($sNative, $oRepos);
  } else {
    return $SINGLETONS{$k};
  }
}

#------------------------------------------------------------------

sub _new {
  my ($sClass, $sNative, $oRepos) = @_;

  # $oRepos is blessed as _p_svn_repos_t
  # to make the methods of this class accessible, we need to have
  # an object that is a member of this class.  However, we can't
  # directly re-bless or else we will get type errors. So instead
  # we wrap it up in a little array.

  my $k="$sClass($sNative)";
  my $self = $SINGLETONS{$k} = bless(\$oRepos, $CLASS);
  Scalar::Util::weaken($SINGLETONS{$k});
  return $self;
}

#==================================================================
# OBJECT METHODS - inherited and overridden
#==================================================================

#------------------------------------------------------------------

sub enableRevProps {
  my ($self, $sScript) = @_;
  my $sPath = $self->getHookFile(PRE_REVPROP);
  $sScript="#!/usr/bin/perl\nexit(0);\n" unless defined($sScript);
  open(my $fh, '>', $sPath)
    or die "Can't open pre-revprop hook file: $!";
  print $fh $sScript;
  close $fh;
  chmod 0755, $sPath;
}

#------------------------------------------------------------------

sub getSvnRepos { return ${$_[0]}; }

#------------------------------------------------------------------

sub getRoot {
  my $self = shift;
  my $oPool = $self->_shiftPool(\@_);
  return SVN::Repos::path($$self, $oPool);
}

#------------------------------------------------------------------

sub getConfDir {
  my $self = shift;
  my $oPool = $self->_shiftPool(\@_);
  return SVN::Repos::conf_dir($$self, $oPool);
}

#------------------------------------------------------------------

sub getDbDir {
  my $self = shift;
  my $oPool = $self->_shiftPool(\@_);
  return SVN::Repos::db_env($$self, $oPool);
}

#------------------------------------------------------------------

sub getDbLogLockFile {
  my $self = shift;
  my $oPool = $self->_shiftPool(\@_);
  return SVN::Repos::db_logs_lockfile($$self,$oPool);
}

#------------------------------------------------------------------

sub getFormat {
  my $self = shift;
  my $sNative = File::Spec->rel2abs('format', $self->getRoot());
  open(my $fh, '<', $sNative) or die "Could not open $sNative: $!";
  my $sLine = <$fh>;
  if (defined($sLine)) {
    chomp $sLine;
    return $sLine;
  } else {
    return undef;
  }}

#------------------------------------------------------------------

sub getHookDir {
  my $self = shift;
  my $oPool = $self->_shiftPool(\@_);
  return SVN::Repos::hook_dir($$self, $oPool);
}

#------------------------------------------------------------------

sub getHookFile {
  my $self      = shift;
  my $crGetHook = shift;
  my $oPool     = $self->_shiftPool(\@_);
  return $crGetHook->($$self, $oPool);
}

#------------------------------------------------------------------

sub getLockDir {
  my $self = shift;
  my $oPool = $self->_shiftPool(\@_);
  return SVN::Repos::lock_dir($$self, $oPool);
}

#------------------------------------------------------------------

sub getSvnserveConfFile {
  my $self = shift;
  my $oPool = $self->_shiftPool(\@_);
  return SVN::Repos::svnserve_conf($$self, $oPool);
}

#------------------------------------------------------------------

sub getHead { $_[0]->getYoungestRevision() };

#------------------------------------------------------------------

sub getFileSystemType {
  my $self = shift;
  return SVN::Fs::type($self->getDbDir());
}

#------------------------------------------------------------------

sub getUUID {
  my ($self, $oPool) = @_;
  return $$self->fs()->get_uuid($oPool);
}

#------------------------------------------------------------------

sub getSwigVersion {
  # Don't use SVN::Repos::version():
  # It returns an svn_version_t struct which claims to be a hash
  # but in fact will complain about FETCH, FIRST_KEY, etc being
  # undefined. In any case, svn_version.h has constants that
  # can be used in its place.
  #my $hVersion = SVN::Repos::version();

  return sprintf("%d.%03d.%03d%s"
                 , $SVN::Core::VER_MAJOR
                 , $SVN::Core::VER_MINOR
                 , $SVN::Core::VER_PATCH
                 , (defined($SVN::Core::VER_NUMTAG)
                    ? $SVN::Core::VER_NUMTAG:'')
                );
}

#------------------------------------------------------------------

sub getYoungestRevision {
  my ($self, $iAprTime) = @_;
  my $oFs = $$self->fs();
  if (defined($iAprTime)) {
    return $oFs->dated_revision($iAprTime);
  } else {
    return $oFs->youngest_rev();
  }
}

#------------------------------------------------------------------

sub setUUID {
  my ($self, $sUuid, $oPool) = @_;
  return $$self->fs()->set_uuid($sUuid, $oPool);
}


##------------------------------------------------------------------

#sub hotcopy {
#  my $self = shift;
#  my $sFrom = shift;
#  my $sTo = shift;
#  my $bCleanLogs = shift;
#  my $oPool = $self->_shiftPool(\@_);
#  return SVN::Repos::hotcopy($self, $sFrom, $sTo, $bCleanLogs, $oPool);
#}

##------------------------------------------------------------------

#sub recover {
#  my $self      = shift;
#  my $crStart   = shift;
#  my $oPool     = $self->_shiftPool(\@_);

#  my $sNative = $self->getRoot();
#  SVN::Repos::recover2($self->getRoot(), $crStart, $oPool);
#}

#------------------------------------------------------------------
# report
#   svn_repos_begin_report   - internal?
#   svn_repos_set_path       - internal?
#   svn_repos_link_path      - internal?
#   svn_repos_delete_path    - internal?
#   svn_repos_finish_report  - internal?
#   svn_repos_abort_report   - internal?
# delta editor
#   svn_repos_node_editor
#   svn_repos_node_from_baton
#   svn_repos_get_commit_editor
#   svn_repos_dir_delta
#   svn_repos_replay
#
# filesystem
#   svn_repos_deleted_rev
#   svn_repos_history
#   svn_repos_trace_node_locations
# filesystem root
#   svn_repos_get_commited_info
#   svn_repos_stat
#   svn_repos_fs_change_node_prop
# filesystem transaction
#   svn_repos_fs_change_txn_prop
#   svn_repos_fs_change_txn_props
#
# authz
#   svn_repos_authz_read
#   svn_repos_authz_check_access
#
# notify action (used by pack)
#   svn_repos_notify_create  - internal?
#
# repository node
# repository dump stream parser
#   svn_repos_get_fs_build_parser
#   svn_repos_parse_dumpstream
#
# repos
#   svn_repos_fs - do we want a separate object?
#   svn_repos_trace_node_location_segments
#   svn_repos_get_logs
#   svn_repos_fs_get_mergeinfo
#   svn_repos_get_file_revs
#   svn_repos_fs_begin_txn_for_commit
#   svn_repos_fs_begin_txn_for_update
#   svn_repos_fs_lock
#   svn_repos_fs_unlock
#   svn_repos_fs_get_locks
#   svn_repos_fs_change_rev_prop
#   svn_repos_fs_revision_prop
#   svn_repos_fs_revision_proplist
#   svn_repos_verify_fs
#   svn_repos_dump
#   svn_repos_load
#   svn_repos_has_capability
#   svn_repos_remember_client_capabilities
#   svn_repos_authz_check_revision_access
#   svn_repos_fs_pack
#   svn_repos_upgrade
#   svn_repos_fs_commit_txn




#==================================================================
# PRIVATE OBJECT METHODS
#==================================================================

sub _shiftPool {
  my $self = shift @_;
  die "Not a $CLASS" unless $self->isa($CLASS);

  my $oPool = shift @{shift @_};

  # Note: it seems that in one release, the default pool was
  # accessible via $SVN::Core->gpool but in a later version, it is
  # returned via a sub, SVN::Core::gpool(). Rather than try to guess
  # which syntax (our vs. sub) we simply don't use the default
  # global pool, gpool.
  #
  # In any case, callers are supposed to be able to temporarily
  # reset the default pool (the pool chosen when $oPool is null). If
  # we always set $oPool to the global pool we interfere with that.
  #
  # We can also run into problems because some C API routines that
  # take file handles leave the current pool with an active reference
  # to that handle.  It is best not to use the global pool in lieu
  # of the default since memory taken from gpool() is not released
  # until subvrsion terminates.
  # return defined($oPool) ? $oPool : $SVN::Core::gpool();

  return $oPool;
}

#==================================================================
# MODULE INITIALIZATION
#==================================================================

1;
