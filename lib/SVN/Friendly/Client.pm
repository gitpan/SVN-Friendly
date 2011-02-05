use strict;
use warnings;
package SVN::Friendly::Client;
my $CLASS = __PACKAGE__;

#--------------------------------------------------------------------
# Note: this method apparently must return 0 to indicate "no error".
# Returning undef results in a "Use of uninitialized value in
# subroutine entry" warning.

our $SYSTEM_DIR_REGEX= qr((?:^|\/)\.svn$);

#--------------------------------------------------------------------
use Scalar::Util;         # looks_like_a_number
use File::Spec;           # curdir, see also addParents
use SVN::Wc;              # needed for fs type/notify constants
use SVN::Client;          # needed for SVN::_Client::svn_client_xxx

use SVN::Friendly::Utils qw(_shiftBoolean _shiftVisitor);
use SVN::Friendly::Dates;

use SVN::Friendly::Config;
my $CONFIG_CLASS='SVN::Friendly::Config';

#--------------------------------------------------------------------
use SVN::Friendly::Exceptions qw(makeErrorHandler);
my $EXCEPTIONS = 'SVN::Friendly::Exceptions';

#--------------------------------------------------------------------
# Fill in missing constants
#--------------------------------------------------------------------

{
  package SVN::Friendly::List::Fields;
  use SVN::Base qw(Core SVN_DIRENT_);
  #for some reason this didn't make it into the SWIG bindings,
  #not at least, the version packaged for Debian-Etch.
  our $ALL=0xFFFFF;
}

{
  package SVN::Wc::Notify::Action;
  our $locked = $SVN::Wc::notify_locked;
  our $unlocked = $SVN::Wc::notify_unlocked;
  our $failed_lock = $SVN::Wc::notify_failed_lock;
  our $failed_unlock = $SVN::Wc::notify_failed_unlock;
}

{
  package SVN::_Core;
  # svn_cmdline.h says that encoding (at least for the command line)
  # defaults to APR_LOCALE_CHARSET, which Apache Portable Runtime
  # Library documentation says is 1, to indicate that the current
  # locale should be used. The apr.i file in the SWIG bindings do
  # not have a mappig for this and 1 causes exceptions. We're setting
  # this to 'UTF-8' in lieu of the proper value.

  #our $svn_locale_charset = 1;
  our $svn_locale_charset = 'UTF-8';
}

# These are needed to set defaults, but aren't in the 1.4.6 SWIG
# bindings. We define them here because Perl won't compile without
# definitions. The values are taken from the C-API header files.

# taken from svn_types.h
{
  package SVN::Depth;

  our $infinity = 3;
  our $empty = 0;
}

#----------------------------------------------------------------
# Log messages
#----------------------------------------------------------------

# this variable is localized with the value of the log message
# it should never be set outside of that context
# see: configureLogMessage(), commit(), copy(), delete(), import()
# mkdir(), propdel(), propset()

our $LOG_MESSAGE;

#----------------------------------------------------------------
# Authentication
#----------------------------------------------------------------

# Providers that don't need any user interaction, placed in order
# of complexity of information needed
#
# - username_provider  = user name only
# - simple_provider    = name + password
# - ssl_server_trust   = ssl certificate, server side
# - ssl_client_cert    = ssl certificate, client side
# - ssl_client_cert_pw = ssl certificate, client side + password
#
# These are all initialized with the global pool

our $SILENT_AUTH_BATON
  = SVN::Core::auth_open(
    [ SVN::Client::get_username_provider()
      , SVN::Client::get_simple_provider()
      , SVN::Client::get_ssl_server_trust_file_provider()
      , SVN::Client::get_ssl_client_cert_file_provider()
      , SVN::Client::get_ssl_client_cert_pw_file_provider()
    ]);

use constant {
  ALL => 0
  , USERNAME => 0
  , USERNAME_PW => 1
  , SIMPLE      => 1       # svn api name for USERNAME_PW
  , SSL_SERVER => 2
  , SSL_CLIENT => 3
  , SSL_CLIENT_PW => 4
  , LAST => 4
};

my $PROVIDER_FACTS
  = [[ 'username'
       ,\&SVN::Client::get_username_provider
       ,\&SVN::Client::get_username_prompt_provider ]
     ,['username_pw'
       ,\&SVN::Client::get_simple_provider
       ,\&SVN::Client::get_simple_prompt_provider ]
     ,['ssl_server'
       ,\&SVN::Client::get_ssl_server_trust_file_provider
       , \&SVN::Client::get_ssl_server_trust_prompt_provider]
     ,['ssl_client'
       ,\&SVN::Client::get_ssl_client_cert_file_provider
       , \&SVN::Client::get_ssl_client_cert_prompt_provider]
     ,['ssl_client_pw'
       ,\&SVN::Client::get_ssl_client_cert_pw_file_provider
       , \&SVN::Client::get_ssl_client_cert_pw_prompt_provider]
    ];

#----------------------------------------------------------------
# Notification
#----------------------------------------------------------------

our %ACTIONS
  = ( $SVN::Wc::Notify::Action::add
      => 'schedule: add'
      , $SVN::Wc::Notify::Action::copy
      => 'schedule: copy'
      , $SVN::Wc::Notify::Action::delete
      => 'schedule: delete'

      , $SVN::Wc::Notify::Action::restore
      => 'revert: deleted file restored'
      , $SVN::Wc::Notify::Action::revert
      => 'revert: addition/modification undone'
      , $SVN::Wc::Notify::Action::failed_revert
      => 'revert: failed'

      , $SVN::Wc::Notify::Action::resolved
      => 'resolved'

      , $SVN::Wc::Notify::Action::skip
      => 'log: skip'
      , $SVN::Wc::Notify::Action::update_add
      => 'update: add'
      , $SVN::Wc::Notify::Action::update_update
      => 'update: update'
      , $SVN::Wc::Notify::Action::update_delete
      => 'update: delete'
      , $SVN::Wc::Notify::Action::update_external
      => 'update: external'
      , $SVN::Wc::Notify::Action::update_completed
      => 'update: completed'

      , $SVN::Wc::Notify::Action::status_external
      => 'status: external'
      , $SVN::Wc::Notify::Action::status_completed
      => 'status: completed'

      , $SVN::Wc::Notify::Action::commit_added
      => 'commit: added'
      , $SVN::Wc::Notify::Action::commit_modified
      => 'commit: modified'
      , $SVN::Wc::Notify::Action::commit_deleted
      => 'commit: deleted'
      , $SVN::Wc::Notify::Action::commit_replaced
      => 'commit: replaced'
      , $SVN::Wc::Notify::Action::commit_postfix_txdelta
      => 'commit: transmitting delta'

      , $SVN::Wc::Notify::Action::blame_revision
      => 'blame: revision'

      , $SVN::Wc::Notify::Action::locked
      => 'locked: suceeded'
      , $SVN::Wc::Notify::Action::unlocked
      => 'unlocked: suceeded'
      , $SVN::Wc::Notify::Action::failed_lock
      => 'lock: failed'
      , $SVN::Wc::Notify::Action::failed_unlock
      => 'unlock: failed'
);


if (1 <= $SVN::Core::VER_MAJOR) {
  if (5 <= $SVN::Core::VER_MINOR) {
    $ACTIONS{$SVN::Wc::Notify::Action::exists}
      = 'schedule: tried to add existing path';
    $ACTIONS{$SVN::Wc::Notify::Action::changelist_set}
      = 'schedule: set changelist';
    $ACTIONS{$SVN::Wc::Notify::Action::changelist_clear}
      = 'schedule: clear changelist';
    $ACTIONS{$SVN::Wc::Notify::Action::changelist_moved}
      = 'schedule: path has moved to new changelist';

    $ACTIONS{$SVN::Wc::Notify::Action::merge_begin}
      = 'merge: begin';
    $ACTIONS{$SVN::Wc::Notify::Action::foreign_merge_begin}
      = 'merge: begin external';

    $ACTIONS{$SVN::Wc::Notify::Action::update_replace}
      = 'update: replace';
  }

  if (6 <= $SVN::Core::VER_MINOR) {
#      , $SVN::Wc::Notify::Action::property_added
#      => 'schedule: add property'
#      , $SVN::Wc::Notify::Action::property_modified
#      => 'schedule: modify property'
#      , $SVN::Wc::Notify::Action::property_deleted
#      => 'schedule: delete property'
#      , $SVN::Wc::Notify::Action::property_deleted_nonexistant
#      => 'schedule: delete property'
#      , $SVN::Wc::Notify::Action::merge_completed
#      => 'merge: completed'
  }
}

sub getActionAsString { $ACTIONS{$_[1]}; }

#--------------------------------------------------------------------
# Additional text equivalents to constants, for testng purposes
#--------------------------------------------------------------------

my %STATUS =
  ( $SVN::Wc::Status::none => 'none'
    , $SVN::Wc::Status::unversioned => 'unversioned'
    , $SVN::Wc::Status::normal => 'exists'
    , $SVN::Wc::Status::added => 'added'
    , $SVN::Wc::Status::missing => 'missing'
    , $SVN::Wc::Status::deleted => 'deleted'
    , $SVN::Wc::Status::replaced => 'replaced'
    , $SVN::Wc::Status::modified => 'modified'
    , $SVN::Wc::Status::merged => 'merged'
    , $SVN::Wc::Status::conflicted => 'conflicted'
    , $SVN::Wc::Status::ignored => 'ignored'
    , $SVN::Wc::Status::obstructed => 'obstructed'
    , $SVN::Wc::Status::external => 'external'
    , $SVN::Wc::Status::incomplete => 'incomplete'
 );
sub getStatusAsString { $STATUS{$_[1]}; }

my %STATE =
  ( $SVN::Wc::notify_state_inapplicable => 'na'
    , $SVN::Wc::Notify::State::unknown => 'unknown'
    , $SVN::Wc::Notify::State::unchanged => 'unchanged'
    , $SVN::Wc::Notify::State::missing => 'missing'
    , $SVN::Wc::Notify::State::obstructed => 'obstructed'
    , $SVN::Wc::Notify::State::changed => 'changed'
    , $SVN::Wc::Notify::State::merged => 'merged'
    , $SVN::Wc::Notify::State::conflicted => 'conflicted'
  );
sub getStateAsString { $STATE{$_[1]} }

my %SCHEDULE =
  ( $SVN::Wc::Schedule::normal => 'normal'
    , $SVN::Wc::Schedule::add => 'add'
    , $SVN::Wc::Schedule::delete => 'delete'
    , $SVN::Wc::Schedule::replace => 'replace'
  );
sub getScheduledOpAsString { $SCHEDULE{$_[1]} }

my %KIND =
  ( $SVN::Node::none => 'none'
    , $SVN::Node::file => 'file'
    , $SVN::Node::dir => 'dir'
    , $SVN::Node::unknown => 'unknown'
  );
sub getKindAsString { $KIND{$_[1]} }

#--------------------------------------------------------------------
# Text equivalents to objects
#--------------------------------------------------------------------

sub getDirEntryString($;$$) {
  my (undef, $sPath, $oDirEntry, $iPrecision) = @_;
  return $sPath unless defined($oDirEntry);

  #long listing
  my $iKind = $oDirEntry->kind();
  my $sKind = $iKind == $SVN::Node::file
    ? 'f' : ($iKind == $SVN::Node::dir ? 'd' : '-');
  my $sProps = ($oDirEntry->has_props() ? 'p' : '-');
  my $sTime = SVN::Friendly::Dates::getISO8601Time
    ($oDirEntry->time(), $iPrecision);

  return sprintf("%5s %s %8s %8s %s %s\n"
                 , $oDirEntry->created_rev()
                 , $sKind . $sProps
                 , $oDirEntry->last_author()
                 , $oDirEntry->size()
                 , $sTime, $sPath);
}

#==================================================================
# CLASS METHODS
#==================================================================

sub new {
  my ($sClass, $xAuth, $xConfig, $xNotify, $crLogMsg, $crCancel
      , $oPool) = @_;
  $oPool = new SVN::Pool() unless defined($oPool);

  my $self = bless({}, $sClass);
  $self->{ctx} = SVN::_Client::svn_client_create_context ();

  $self->configureAuthentication($xAuth);
  $self->setConfig($xConfig);
  $self->configureNotification($xNotify);
  $self->configureLogMessage($crLogMsg);
  $self->configureCancellation($crCancel);
  $self->setPool($oPool);
  return $self;
}

#==================================================================
# OBJECT METHODS - non-overridable
#==================================================================

#----------------------------------------------------------------

sub getWorkingCopyRevision {
  my ($self, $sWc) = @_;

  my ($iCurrentRev, $iLastChangedRev);
  my $crInfo = sub {
    my ($sWc, $oInfo, $oPool) = @_;
    $iCurrentRev = $oInfo->rev();
    $iLastChangedRev = $oInfo->last_changed_rev();
  };
  $self->info($sWc, $crInfo);
  return [$iCurrentRev, $iLastChangedRev];
}

#----------------------------------------------------------------

sub getWorkingCopyDirStatus {
  my ($self, $sWc) = @_;
  my $iStatus =  $SVN::Wc::Status::unversioned;
  #print STDERR "getWorkingCopyDir: <$sWc>\n";

  local $SVN::Error::handler = makeErrorHandler
      (sub {
         my $iErr = $_[0]->apr_err();
         #print STDERR "error no: $iErr\n";
         if ($iErr eq $SVN::Error::RA_ILLEGAL_URL) {
           #$SVN::Error::RA_ILLEGAL_URL appears to be thrown when
           #$sWc is added but not committed
           $iStatus = $SVN::Wc::Status::added;
           return 1; #don't croak - we know added

         } elsif ($iErr eq $SVN::Error::ENTRY_MISSING_URL) {
           #$SVN::Error::ENTRY_MISSING_URL appears to be thrown when
           #$sWc is not added, but parent of $sWc is added and
           #committed
           return 1; #don't croak - we know unversioned

         } elsif ($iErr eq $SVN::Error::WC_NOT_DIRECTORY) {
           #$SVN::Error::WC_NOT_DIRECTORY appears to be thrown when
           #$sWc is not added, and immediate parent of $sWc is not
           #a working directory
           return 1; #don't croak - we know unversioned

         } else {
           return 0; #croak - don't know what went wrong
         }
       });

  my $crInfo = sub {
    my ($sWc, $oInfo, $oPool) = @_;
    $iStatus = $SVN::Wc::Status::normal
      unless ($oInfo->kind() eq $SVN::Node::unknown);
  };

  $self->info($sWc, $crInfo);
  #print STDERR "getWorkingCopyDir: <$sWc> <$iStatus>\n";
  return $iStatus;
}

#----------------------------------------------------------------
sub isWorkingCopyPath {
  #print STDERR "isWorkingCopyPath:<$SVN::Wc::Status::unversioned>\n";
  return getWorkingCopyDirStatus(@_) eq  $SVN::Wc::Status::unversioned
    ? 0 : 1;
}

#----------------------------------------------------------------

sub printStatus {
  my ($self, $sWc, $fh) = @_;
  my $crStatus = sub {
    my ($sWc, $oStatus) = @_;

    #Note: only 1.2+ API (status2) supports flag to indicate whether
    #file is locked in the repository. The locked flag returned by
    #locked() really should be frozen or interrupted. It refers to
    #file that are "locked" because their modifications have only
    #been partially stored in the repository.

    my $iTextStatus = $oStatus->text_status();
    my $iPropStatus = $oStatus->prop_status();
    my $sStatus = sprintf("%-11s %-11s %s\n"
      , $SVN::Friendly::Client::STATUS{$iTextStatus}
      , $SVN::Friendly::Client::STATUS{$iPropStatus}
      , $sWc);
    print $fh $sStatus;
  };
  $self->status($sWc, $crStatus);
}

#----------------------------------------------------------------

sub add1_1 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_add
    ($sWc, $bRecurse, $self->{ctx}, $oPool);
}

sub add1_4 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bForceAdd            = _shiftBoolean(\@_);
  my $bNoIgnore            = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #bForceAdd - descend into versioned dirs
  #            skip versioned files silently

  return SVN::_Client::svn_client_add3
    ($sWc, $bRecurse, $bForceAdd, $bNoIgnore
     , $self->{ctx}, $oPool);
}

sub add1_5 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bForceAdd            = _shiftBoolean(\@_);
  my $bNoIgnore            = _shiftBoolean(\@_);
  my $bAddParents          = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #bForceAdd - descend into versioned dirs
  #            skip versioned files silently

  return SVN::_Client::svn_client_add4
    ($sWc, $iDepth, $bForceAdd, $bNoIgnore, $bAddParents
     , $self->{ctx}, $oPool);
}

*add1_6 = *add1_5;
*add1_7 = *add1_7;
*add    = *add1_1;

#----------------------------------------------------------------

sub blame1_1 {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my ($xStart, $xEnd)      = _shiftRange(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #Despite the fact that the usage string includes a baton,
  #the actual method expects it to be omitted from the parameter
  #list

  return SVN::_Client::svn_client_blame
    ($xRepos, $xStart, $xEnd, $crVisit, $self->{ctx}, $oPool);
}

sub blame1_4 {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my ($xStart, $xEnd)      = _shiftRange(\@_, $xPeg);
  my $oDiffOptions         = shift @_;
  my $bBlameBinary         = _shiftBoolean(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #Despite the fact that the usage string includes a baton,
  #the actual method expects it to be omitted from the parameter
  #list

  $oDiffOptions = SVN::_Core::svn_diff_file_options_create($oPool)
    unless defined($oDiffOptions);

  return SVN::_Client::svn_client_blame3
    ($xRepos, $xPeg, $xStart, $xEnd
     , $oDiffOptions, $bBlameBinary, $crVisit
     , $self->{ctx}, $oPool);
}

sub blame1_5 {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my ($xStart, $xEnd)      = _shiftRange(\@_);
  my $oDiffOptions         = shift @_;
  my $bBlameBinary         = _shiftBoolean(\@_);
  my $bIncludeMergedRevisions = _shiftBoolean(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #Despite the fact that the usage string includes a baton,
  #the actual method expects it to be omitted from the parameter
  #list

  $oDiffOptions = SVN::_Core::svn_diff_file_options_create($oPool)
    unless defined($oDiffOptions);

  return SVN::_Client::svn_client_blame4
    ($xRepos, $xPeg, $xStart, $xEnd, $bBlameBinary
    , $bIncludeMergedRevisions, $crVisit, $self->{ctx}, $oPool);
}

sub blame1_6 {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my ($xStart, $xEnd)      = _shiftRange(\@_);
  my $oDiffOptions         = shift @_;
  my $bBlameBinary         = _shiftBoolean(\@_);
  my $bIncludeMergedRevisions = _shiftBoolean(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #Despite the fact that the usage string includes a baton,
  #the actual method expects it to be omitted from the parameter
  #list

  $oDiffOptions = SVN::_Core::svn_diff_file_options_create($oPool)
    unless defined($oDiffOptions);

  return SVN::_Client::svn_client_blame5
    ($xRepos, $xPeg, $xStart, $xEnd, $bBlameBinary
    , $bIncludeMergedRevisions, $crVisit, $self->{ctx}, $oPool);
}

*blame1_7 = *blame1_6;
*blame    = *blame1_1;

#----------------------------------------------------------------

sub cat1_1 {
  my $self                 = shift @_;
  my $fh                   = _shiftOutFile(\@_);
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_cat
    ($fh, $xRepos, $xPeg, $self->{ctx}, $oPool);
}

sub cat1_4($;$$$) {
  my $self                 = shift @_;
  my $fh                   = _shiftOutFile(\@_);
  my $xRepos               = _shiftTarget(\@_);
  my ($xPeg, $xRev)        = _shiftPegRev(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_cat2
    ($fh, $xRepos, $xPeg, $xRev, $self->{ctx}, $oPool);
}

*cat1_5 = *cat1_4;
*cat1_6 = *cat1_4;
*cat1_7 = *cat1_4;

sub cat {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $fh                   = _shiftOutFile(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_cat
    ($fh, $xRepos, $xPeg, $self->{ctx}, $oPool);
}

#----------------------------------------------------------------

sub checkout1_1 {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $sWc                  = _shiftWcPath(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_checkout
    ($xRepos, $sWc, $xPeg, $bRecurse, $self->{ctx}, $oPool);
}

sub checkout1_4 {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $sWc                  = _shiftWcPath(\@_);
  my ($xPeg, $xTargetRev)  = _shiftPegRev(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_checkout2
    ($xRepos, $sWc, $xPeg, $xTargetRev, $bRecurse, $bSkipExternals
     , $self->{ctx}, $oPool);
}

sub checkout1_5 {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $sWc                  = _shiftWcPath(\@_);
  my ($xPeg, $xTargetRev)  = _shiftPegRev(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $bAllowUnversionedObstructions = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_checkout3
    ($xRepos, $sWc, $xPeg, $xTargetRev, $iDepth, $bSkipExternals
     , $bAllowUnversionedObstructions, $self->{ctx}, $oPool);
}

*checkout1_6 = *checkout1_5;
*checkout1_7 = *checkout1_5;

sub checkout {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $sWc                  = _shiftWcPath(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_checkout
    ($xRepos, $sWc, $xPeg, $bRecurse, $self->{ctx}, $oPool);
}

#----------------------------------------------------------------

sub cleanup1_1 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_cleanup
    ($sWc, $self->{ctx}, $oPool);
}

*cleanup1_4 = *cleanup1_1;
*cleanup1_5 = *cleanup1_1;
*cleanup1_6 = *cleanup1_1;
*cleanup1_7 = *cleanup1_1;
*cleanup = *cleanup1_1;

#----------------------------------------------------------------

sub commit1_1 {
  my $self                 = shift @_;
  my $aWcs                 = _shiftWcPaths(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bNonRecursive        = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_commit
    ($aWcs, $bNonRecursive, $self->{ctx}, $oPool);
}

sub commit1_4 {
  my $self                 = shift @_;
  my $aWcs                 = _shiftWcPaths(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bKeepLocks           = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_commit3
    ($aWcs, $bRecurse, $bKeepLocks, $self->{ctx}, $oPool);
}

sub commit1_5 {
  my $self                 = shift @_;
  my $aWcs                 = _shiftWcPaths(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bKeepLocks           = _shiftBoolean(\@_);
  my $bKeepChangelists     = _shiftBoolean(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_commit4
    ($aWcs, $iDepth, $bKeepLocks, $bKeepChangelists, $aChangeLists
     , $hRevProps, $self->{ctx}, $oPool);
}

*commit1_6 = *commit1_5;

sub commit1_7 {
  my $self                 = shift @_;
  my $aWcs                 = _shiftWcPaths(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bKeepLocks           = _shiftBoolean(\@_);
  my $bKeepChangelists     = _shiftBoolean(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $crCommit             = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_commit4
    ($aWcs, $iDepth, $bKeepLocks, $bKeepChangelists, $aChangeLists
     , $hRevProps, $crCommit, $self->{ctx}, $oPool);
}

sub commit {
  my $self                 = shift @_;
  my $aWcs                 = _shiftWcPaths(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_commit
      ($aWcs, $bRecurse?0:1, $self->{ctx}, $oPool);
}

#--------------------------------------------------------------------

sub configureAuthentication {
  my ($self, $oAuthBaton) = @_;
  my $sRef=ref($oAuthBaton);
  my $acrPrompters;

  if (!defined($oAuthBaton)) {
    $oAuthBaton = $SILENT_AUTH_BATON;
    $acrPrompters = [];
  } elsif ($sRef eq '_p_svn_auth_baton_t') {
    $acrPrompters = [];
  } elsif ($sRef eq 'ARRAY') {
    ($oAuthBaton, $acrPrompters)
      = SVN::Core::auth_open_helper($oAuthBaton);

  } elsif ($sRef eq 'HASH') {
    my $hProps = $oAuthBaton;
    my $oPool = $hProps->{pool};
    my $iRetries = $hProps->{retries};
    $iRetries = 3 unless defined($iRetries);

    my $xProviders = $hProps->{providers};
    my $aProviders = !defined($xProviders)
        ? $PROVIDER_FACTS
        : ref($xProviders)
          ? [ @$PROVIDER_FACTS[@$xProviders] ]
          : [ @$PROVIDER_FACTS[$xProviders..LAST]];

    my $aAuth = [];
    foreach (@$aProviders) {
      my ($k, $crSilent, $crPrompt) = @$_;

      my $aData = exists($hProps->{$k}) ? $hProps->{$k} : undef;
      if (!defined($aData) && ($k eq 'username_pw')) {
        # simple is an alias for username_pw
        $k='simple';
        $aData = exists($hProps->{$k}) ? $hProps->{$k} : undef;
      }
      $aData = [ $aData, undef ] if (ref($aData) eq 'CODE');

      my ($crCallback, $bNoSilent) =  defined($aData) ? @$aData : ();

      #printf STDERR "k=$k, prompt=%s silent=%s\n"
      #  , (defined($crCallback)?$crCallback:'undef')
      #  , ($bNoSilent ? 0 : 1);

      push @$aAuth, $crSilent->($oPool) unless $bNoSilent;

      if (defined($crCallback)) {
        my $oProvider = $k eq 'ssl_server'
          ? $crPrompt->($crCallback, $oPool)
          : $crPrompt->($crCallback, $iRetries, $oPool);
        push @$aAuth, $oProvider;
      }

    }
    ($oAuthBaton, $acrPrompters)= SVN::Core::auth_open_helper($aAuth);
  } else {
    die $EXCEPTIONS->ERR_BAD_ARG
      ->new(arg => $oAuthBaton, reason=>"Configuration object must "
            . "be a hash reference, array of providers, "
            . "authentication baton, or undefined");
  }

  # Not sure why the callbacks need to be held onto, perhaps to keep
  # the reference from being garbage cleaned?  In any case,
  # SVN::Client does this, so we shall too.

  $self->{ctx}->auth_baton($oAuthBaton);
  $self->{auth_callbacks} = $acrPrompters;
  return ($self->{ctx}->auth_baton(), $self->{auth_callbacks});
}

#--------------------------------------------------------------------

sub configureCancellation {
  my ($self, $crCancel) = @_;
  if (defined($crCancel) && (ref($crCancel) ne 'CODE')) {
    die $EXCEPTIONS->ERR_BAD_ARG->new(arg => $crCancel, reason => "Cancel "
       ."callback must be undefined a code reference");
  }
  $self->{cancel} =$self->{ctx}->cancel_baton($crCancel);
  return $crCancel;
}

#--------------------------------------------------------------------

sub configureLogMessage {
  my ($self, $crLogMsg) = @_;
  my $crWrapper;

  if (defined($crLogMsg)) {
    if (ref($crLogMsg) eq 'CODE') {
      $crWrapper = sub {
        my ($rMsg, $sTmpFile, $aCommit, $oPool) = @_;
        $$rMsg = $LOG_MESSAGE;
        return defined($crLogMsg)
          ? $crLogMsg->($rMsg, $sTmpFile, $aCommit, $oPool) : 0;
      };
    } else {
      die $EXCEPTIONS->ERR_BAD_ARG->new(arg => $crLogMsg, reason => "Log message "
        . "callback must be undefined, a hash, or a code reference");
    }
  } else {
    $crWrapper = sub {
      die $EXCEPTIONS->ERR_NO_LOG_MSG->new()
        unless defined($LOG_MESSAGE);
      ${$_[0]} = $LOG_MESSAGE;
    }
  }

  $self->{log_msg_wrapper} = $self->{ctx}->log_msg_baton($crWrapper);
  $self->{log_msg} = $crLogMsg;
  return $crLogMsg;
}

#--------------------------------------------------------------------

sub configureNotification {
  my ($self,$crNotify) = @_;
  if (defined($crNotify)) {
    my $sRef = ref($crNotify);
    if ($sRef eq 'HASH') {
      my $hActions = $crNotify;
      $crNotify = sub {
        #my ($sPath, $iAction, $iKind, $sMime,$iState,$iRevision)=@_;
        return _notifyFromHash($hActions, @_);
      };
    } elsif ($sRef ne 'CODE') {
      die $EXCEPTIONS->ERR_BAD_ARG->new(arg => $crNotify, reason => "Notification "
        . "callback must be undefined, a hash, or a code reference");
    }
  }
  $self->{notify} =$self->{ctx}->notify_baton($crNotify);
  return $crNotify;
}

#--------------------------------------------------------------------
# command line:
# - can't copy to an uncommited directory
#   * not smart enough to add the directory
# - can't copy an uncommited file
#   * not smart enough to convert copy X to Y to add Y
# - can't copy over an existing file
#   * no parameter to force overwrite
#
# - copying a file to X and deleting X and replacing it with a
#   dir of the same name before commit will result
#   in an inconsistent working copy state that can only be fixed
#   by running "svn update X". even deleting the dir and running
#   just plain "svn update" will not work
#
# ==> copy only: file (w/ or w/o mod) to non-existing file
#                file (w/ or w/o mod) to committed dir
#
# to copy X to Y and then schedule copy
#   method A:
#   - in repository: copy from-HEAD to-HEAD
#   - rename Y to tmpfile  (to avoid can't update complaints)
#   - update Y         (bring copy down from server
#   - copy tmpfile to Y  (restore changes, now viewed as "mod")
#   - commit change
#   Notes:
#   - adding before update doesn't help, still won't update
#   - committing before update doesn't help, won't commit
#   - there is no force flag
#   - why doesn't this just merge or treat as conflict?
#

sub copy1_1 {
  my $self                 = shift @_;
  my $sTarget              = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_, 1);
  my $sTo                  = _shiftTarget(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #print STDERR "copy: <$sTarget> <$sTo>\n";

  return SVN::_Client::svn_client_copy
    ($sTarget, $xPeg, $sTo, $self->{ctx}, $oPool);
}

sub copy1_4 {
  my $self                 = shift @_;
  my $sTarget              = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_, 1);
  my $sTo                  = _shiftTarget(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_copy3
    ($sTarget, $xPeg, $sTo, $self->{ctx}, $oPool);
}


sub copy1_5 {
  my $self                 = shift @_;
  my $aTargets             = _shiftTargets(\@_);
  my $xPeg                 = _shiftPeg(\@_, 1);
  my $sTo                  = _shiftTarget(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bCopyAsChild         = _shiftBoolean(\@_);
  my $bMakeParents         = _shiftBoolean(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_copy4
    ($aTargets, $xPeg, $sTo, $bCopyAsChild, $bMakeParents
     , $hRevProps, $self->{ctx}, $oPool);
}

sub copy1_6 {
  my $self                 = shift @_;
  my $aTargets             = _shiftTargets(\@_);
  my $xPeg                 = _shiftPeg(\@_, 1);
  my $sTo                  = _shiftTarget(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bCopyAsChild         = _shiftBoolean(\@_);
  my $bMakeParents         = _shiftBoolean(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_copy5
    ($aTargets, $xPeg, $sTo, $bCopyAsChild, $bMakeParents
     , $hRevProps, $self->{ctx}, $oPool);
}

sub copy1_7 {
  my $self                 = shift @_;
  my $aTargets             = _shiftTargets(\@_);
  my $xPeg                 = _shiftPeg(\@_, 1);
  my $sTo                  = _shiftTarget(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bCopyAsChild         = _shiftBoolean(\@_);
  my $bMakeParents         = _shiftBoolean(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $crCommit             = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_copy6
    ($aTargets, $xPeg, $sTo, $bCopyAsChild, $bMakeParents
     , $hRevProps, $crCommit, $self->{ctx}, $oPool);
}

*copy = *copy1_1;

#----------------------------------------------------------------
# delete after add    - only allowed with force=true
# delete after mod    - only allowed with force=true
# delete, then add    - fails, won't restore
# delete, then update - fails, won't restore
# delete, then copy from repository to current
#    - only way to restore failed delete, marked as replacement

sub delete1_1 {
  my $self                 = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_delete
    ($xTargets, $bForce, $self->{ctx}, $oPool);
}

sub delete1_4 {
  my $self                 = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_delete2
    ($xTargets, $bForce, $self->{ctx}, $oPool);
}

sub delete1_5 {
  my $self                 = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $bKeepLocal           = _shiftBoolean(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_delete3
    ($xTargets, $bForce, $bKeepLocal, $hRevProps, $self->{ctx}
     , $oPool);
}

*delete1_6 = *delete1_5;

sub delete1_7 {
  my $self                 = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $bKeepLocal           = _shiftBoolean(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $crCommit             = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_delete4
    ($xTargets, $bForce, $bKeepLocal, $hRevProps, $crCommit
     , $self->{ctx}, $oPool);
}

*delete = *delete1_1;

#----------------------------------------------------------------

sub diff1_1 {
  my $self                 = shift @_;
  my $aCmdLineOptions      = _shiftArray(\@_);
  my ($xTarget1, $xPeg1
      , $xTarget2, $xPeg2) = _shiftDiffTargets(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bIgnoreAncestry      = _shiftBoolean(\@_);
  my $bIgnoreDeleted       = _shiftBoolean(\@_);
  my $xOutFile             = _shiftOutFile(\@_);
  my $xErrFile             = _shiftErrFile(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_diff
    ($aCmdLineOptions, $xTarget1, $xPeg1, $xTarget2, $xPeg2
     , $bRecurse, $bIgnoreAncestry, $bIgnoreDeleted
     , $xOutFile, $xErrFile, $self->{ctx},  $oPool);
}

sub diff1_4 {
  my $self                 = shift @_;
  my $aCmdLineOptions      = _shiftArray(\@_);
  my ($xTarget1, $xPeg1
      , $xTarget2, $xPeg2) = _shiftDiffTargets(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bIgnoreAncestry      = _shiftBoolean(\@_);
  my $bIgnoreDeleted       = _shiftBoolean(\@_);
  my $bDiffBinary          = _shiftBoolean(\@_);
  my $sHeaderEncoding      = _shiftOutputEncoding(\@_);
  my $xOutFile             = _shiftOutFile(\@_);
  my $xErrFile             = _shiftErrFile(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_diff3
    ($aCmdLineOptions, $xTarget1, $xPeg1, $xTarget2, $xPeg2
     , $bRecurse, $bIgnoreAncestry, $bIgnoreDeleted
     , $bDiffBinary, $sHeaderEncoding
     , $xOutFile, $xErrFile, $self->{ctx},  $oPool);
}

sub diff1_5 {
  my $self                 = shift @_;
  my $aCmdLineOptions      = _shiftArray(\@_);
  my ($xTarget1, $xPeg1
      , $xTarget2, $xPeg2) = _shiftDiffTargets(\@_);
  my $bRelativeToDir       = _shiftBoolean(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bIgnoreAncestry      = _shiftBoolean(\@_);
  my $bIgnoreDeleted       = _shiftBoolean(\@_);
  my $bDiffBinary          = _shiftBoolean(\@_);
  my $sHeaderEncoding      = _shiftOutputEncoding(\@_);
  my $xOutFile             = _shiftOutFile(\@_);
  my $xErrFile             = _shiftErrFile(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $oPool                = $self->_shiftPool(\@_);


  return SVN::_Client::svn_client_diff4
    ($aCmdLineOptions, $xTarget1, $xPeg1, $xTarget2, $xPeg2
     , $bRelativeToDir, $iDepth, $bIgnoreAncestry, $bIgnoreDeleted
     , $bDiffBinary, $sHeaderEncoding, $xOutFile, $xErrFile
     , $aChangeLists, $self->{ctx},  $oPool);
}

*diff1_6 = *diff1_5;

sub diff1_7 {
  my $self                 = shift @_;
  my $aCmdLineOptions      = _shiftArray(\@_);
  my ($xTarget1, $xPeg1
      , $xTarget2, $xPeg2) = _shiftDiffTargets(\@_);
  my $bRelativeToDir       = _shiftBoolean(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bIgnoreAncestry      = _shiftBoolean(\@_);
  my $bIgnoreDeleted       = _shiftBoolean(\@_);
  my $bShowCopiesAsAdds    = _shiftBoolean(\@_);
  my $bDiffBinary          = _shiftBoolean(\@_);
  my $bUseGitDiffFormat    = _shiftBoolean(\@_);
  my $sHeaderEncoding      = _shiftOutputEncoding(\@_);
  my $xOutFile             = _shiftOutFile(\@_);
  my $xErrFile             = _shiftErrFile(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $oPool                = $self->_shiftPool(\@_);


  return SVN::_Client::svn_client_diff5
    ($aCmdLineOptions, $xTarget1, $xPeg1, $xTarget2, $xPeg2
     , $bRelativeToDir, $iDepth, $bIgnoreAncestry, $bIgnoreDeleted
     , $bShowCopiesAsAdds, $bDiffBinary, $bUseGitDiffFormat
     , $sHeaderEncoding, $xOutFile, $xErrFile
     , $aChangeLists, $self->{ctx},  $oPool);
}

sub diff {
  my $self                 = shift @_;
  my ($xTarget1, $xPeg1
      , $xTarget2, $xPeg2) = _shiftDiffTargets(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $aCmdLineOptions      = _shiftArray(\@_);
  my $bIgnoreAncestry      = _shiftBoolean(\@_);
  my $bIgnoreDeleted       = _shiftBoolean(\@_);
  my $xOutFile             = _shiftOutFile(\@_);
  my $xErrFile             = _shiftErrFile(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_diff
    ($aCmdLineOptions, $xTarget1, $xPeg1, $xTarget2, $xPeg2
     , $bRecurse, $bIgnoreAncestry, $bIgnoreDeleted
     , $xOutFile, $xErrFile, $self->{ctx},  $oPool);
}

#----------------------------------------------------------------

sub export1_1 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $xToPath              = _shiftWcPath(\@_);
  my $xPeg                 = _shiftPeg(\@_, 1);
  my $bOverwrite           = _shiftBoolean(\@_);
  my $sNativeEol           = _shiftOutputEol(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_export2
    ($xTarget, $xToPath, $xPeg, $bOverwrite, $sNativeEol
    , $self->{ctx}, $oPool);
}

sub export1_4 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $xToPath              = _shiftWcPath(\@_);
  my ($xPeg, $xRev)        = _shiftPegRev(\@_, 1);
  my $bOverwrite           = _shiftBoolean(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $sNativeEol           = _shiftOutputEol(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_export3
    ($xTarget, $xToPath, $xPeg, $xRev, $bOverwrite, $bSkipExternals
    , $bRecurse, $sNativeEol, $self->{ctx}, $oPool);
}


sub export1_5 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $xToPath              = _shiftWcPath(\@_);
  my ($xPeg, $xRev)        = _shiftPegRev(\@_, 1);
  my $bOverwrite           = _shiftBoolean(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $sNativeEol           = _shiftOutputEol(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_export4
    ($xTarget, $xToPath, $xPeg, $xRev, $bOverwrite, $bSkipExternals
     , $iDepth, $sNativeEol, $self->{ctx}, $oPool);
}

*export1_6=*export1_5;

sub export1_7 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $xToPath              = _shiftWcPath(\@_);
  my ($xPeg, $xRev)        = _shiftPegRev(\@_, 1);
  my $bOverwrite           = _shiftBoolean(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $bIgnoreKeywords      = _shiftBoolean(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $sNativeEol           = _shiftOutputEol(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_export5
    ($xTarget, $xToPath, $xPeg, $xRev, $bOverwrite, $bSkipExternals
     , $bIgnoreKeywords, $iDepth, $sNativeEol, $self->{ctx}, $oPool);
}

sub export {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_, 1);
  my $xToPath              = _shiftWcPath(\@_);
  my $bOverwrite           = _shiftBoolean(\@_);
  my $sNativeEol           = _shiftOutputEol(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_export2
    ($xTarget, $xToPath, $xPeg, $bOverwrite, $sNativeEol
    , $self->{ctx}, $oPool);
}
#---------------------------------------------------------------------

sub getAuthentication {
  my $self = $_[0];
  return ($self->{ctx}->auth_baton(), $self->{auth_callbacks});
}
#---------------------------------------------------------------------

sub getCancellationCallback {
  my $crCancel = $_[0]->{cancel};
  return defined($crCancel) ? $$crCancel : undef;
}

#---------------------------------------------------------------------

sub getConfig { return $CONFIG_CLASS->new($_[0]->{ctx}->config()); }

#---------------------------------------------------------------------

sub getInfo {
  my ($self, $sWc, $xPeg, $oPool) = @_;
  my $oInfo;
  my $crVisit = sub { $oInfo=$_[1] };
  $self->info($sWc, $xPeg, $crVisit, 0, $oPool);
  return $oInfo;
}

#---------------------------------------------------------------------

sub getLogMessageCallback {
  return $_[0]->{log_msg};
}

#---------------------------------------------------------------------

sub getNotificationCallback {
  my $crNotify = $_[0]->{notify};
  return defined($crNotify) ? $$crNotify : undef;
}

#----------------------------------------------------------------

sub getPathList {
  my ($self, $xPath, $xPeg, $bRecurse, $oPool) = @_;
  my $hEntries = $self->ls1_1($xPath, $xPeg, $bRecurse, $oPool);
  return defined($hEntries) ? [ keys %$hEntries ] : [];
}

#----------------------------------------------------------------

sub getPathProperty {
  my ($self, $sPath, $sProp, $xPeg) = @_;
  my $hProp = $self->propget($sPath, $sProp, $xPeg, 0);
  return (values %$hProp)[0];
}

#----------------------------------------------------------------

sub getPathProperties {
  my ($self, $sPath, $xPeg) = @_;

  my $aNodes = $self->proplist($sPath, $xPeg, 0);
  my $oNode = defined($aNodes) && exists($aNodes->[0])
    ? $aNodes->[0] : undef;
  return defined($oNode) ? $oNode->prop_hash() : {};
}

#---------------------------------------------------------------------

sub getPool { $_[0]->{pool} }

#----------------------------------------------------------------

sub getRepositoryRootURL {
  my ($self, $sWc, $oPool) = @_;
  my $sRoot;
  my $crVisit = sub { $sRoot = $_[1]->repos_root_URL() };
  $self->info($sWc, $crVisit, 0, $oPool);
  return $sRoot;
}

#----------------------------------------------------------------
# returns the equivalent path in the repository

sub getRepositoryURL {
  my ($self, $sWc, $oPool) = @_;

  $oPool = $self->{pool} unless defined($oPool);
  return SVN::_Client::svn_client_url_from_path($sWc, $oPool);
}

#----------------------------------------------------------------

sub getRepositoryUUID {
  my ($self, $sWc, $oPool) = @_;

  $oPool = $self->{pool} unless defined($oPool);

  #try first to get this information locally
  #on older versions it may not be available
  my $oAdminBaton = SVN::_Wc::svn_wc_adm_probe_open3
    (undef, $sWc, 0, 0, undef, undef, $oPool);
  if ($oAdminBaton) {
    return SVN::_Client::svn_client_uuid_from_path
      ($sWc, $oAdminBaton, $self->{ctx}, $oPool);
  }

  my $xRepos
    = SVN::_Client::svn_client_url_from_path($sWc, $oPool);
  return SVN::_Client::svn_client_uuid_from_url
    ($xRepos, $self->{ctx}, $oPool);
}

#----------------------------------------------------------------

sub getRevisionProperty {
  my ($self, $xRepos, $sProp, $xPeg) = @_;
  my @aGot = $self->revprop_get($xRepos, $sProp, $xPeg);
  return exists($aGot[0]) ? $aGot[0] : undef;
}

#----------------------------------------------------------------

sub getRevisionProperties {
  my ($self, $xRepos, $xPeg, $sProp) = @_;
  my @aGot = $self->revprop_list($xRepos, $xPeg);
  return exists($aGot[0])? $aGot[0] : {};
}

#----------------------------------------------------------------

sub getStatus {
  my ($self, $sWc, $oPool) = @_;
  $oPool = $self->{pool} unless defined($oPool);

  my $iErr;
  local $SVN::Error::handler = makeErrorHandler
      (sub {
         $iErr = $_[0]->apr_err();
         if ($iErr eq $SVN::Error::WC_NOT_DIRECTORY) {
           return 1;
         }
         return 0;
       });

  my $oAdminBaton = SVN::_Wc::svn_wc_adm_probe_open3
    (undef, $sWc, 0, 0, undef, undef, $oPool);
  return $iErr
    ? undef : SVN::_Wc::svn_wc_status($sWc, $oAdminBaton, $oPool);
}

#----------------------------------------------------------------

sub import1_1 {
  my $self = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xRepos               = _shiftTarget(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bNonRecursive        = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_import
    ($sWc, $xRepos, $bNonRecursive, $self->{ctx}, $oPool);
}


sub import1_4 {
  my $self = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xRepos               = _shiftTarget(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bNonRecursive        = _shiftBoolean(\@_);
  my $bNoIgnore            = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_import2
    ($sWc, $xRepos, $bNonRecursive, $bNoIgnore, $self->{ctx}, $oPool);
}

sub import1_5 {
  my $self = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xRepos               = _shiftTarget(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bNoIgnore            = _shiftBoolean(\@_);
  my $bIgnoreUnknownNodeTypes = _shiftBoolean(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_import3
    ($sWc, $xRepos, $iDepth, $bNoIgnore, $bIgnoreUnknownNodeTypes
    , $hRevProps, $self->{ctx}, $oPool);
}

*import1_6 = *import1_5;


sub import1_7 {
  my $self = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xRepos               = _shiftTarget(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bNoIgnore            = _shiftBoolean(\@_);
  my $bIgnoreUnknownNodeTypes = _shiftBoolean(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $crCommit             = _shiftVisitor(@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_import4
    ($sWc, $xRepos, $iDepth, $bNoIgnore, $bIgnoreUnknownNodeTypes
     , $hRevProps, $crCommit, $self->{ctx}, $oPool);
}

sub import {
  my $self = shift @_;
  return unless ref($self);  #play nicely when called by use...

  my $sWc                  = _shiftWcPath(\@_);
  my $xRepos               = _shiftTarget(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_import
    ($sWc, $xRepos, $bRecurse?0:1, $self->{ctx}, $oPool);
}

#----------------------------------------------------------------

sub info1_1 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my ($xPeg,$xTargetRev)   = _shiftPegRev(\@_,1);
  my $crVisit              = _shiftVisitor(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #omit the baton - despite it being included in the usage
  #statement, svn_client_log expects the $_[5] to be the context
  return SVN::_Client::svn_client_info
    ($xTarget, $xPeg, $xTargetRev, $crVisit, $bRecurse
     , $self->{ctx}, $oPool);
}

*info1_4=*info1_1;

sub info1_5 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my ($xPeg,$xTargetRev)   = _shiftPegRev(\@_,1);
  my $crVisit              = _shiftVisitor(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #omit the baton - despite it being included in the usage
  #statement, svn_client_log expects the $_[5] to be the context
  return SVN::_Client::svn_client_info2
    ($xTarget, $xPeg, $xTargetRev, $crVisit, $iDepth, $aChangeLists
     , $self->{ctx}, $oPool);
}

*info1_6=*info1_5;

sub info1_7 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my ($xPeg,$xTargetRev)   = _shiftPegRev(\@_,1);
  my $crVisit              = _shiftVisitor(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #omit the baton - despite it being included in the usage
  #statement, svn_client_log expects the $_[5] to be the context
  return SVN::_Client::svn_client_info3
    ($xTarget, $xPeg, $xTargetRev, $crVisit, $iDepth, $aChangeLists
     , $self->{ctx}, $oPool);
}

*info=*info1_1;

#----------------------------------------------------------------

sub isLocked {
  my ($self, $sWc, $xPeg, $oPool) = @_;
  return $self->getInfo($sWc, $xPeg, $oPool)->lock() ? 1 : 0;
}

#----------------------------------------------------------------

sub lock1_1 {
  my $self                 = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  my $sComment             = _shiftString(\@_);
  my $bStealLock           = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_lock
    ($xTargets, $sComment, $bStealLock, $self->{ctx}, $oPool);
}

*lock1_4 = *lock1_1;
*lock1_5 = *lock1_1;
*lock1_6 = *lock1_1;
*lock1_7 = *lock1_1;
*lock = *lock1_1;

#----------------------------------------------------------------

sub log1_1 {
  my $self = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  my ($xStart, $xEnd)      = _shiftRange(\@_);
  my $bChangedPaths        = _shiftBoolean(\@_);
  my $bStrictNodeHistory   = _shiftBoolean(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #omit the baton - despite it being included in the usage
  #statement, svn_client_log expects the $_[6] to be the context
  return SVN::_Client::svn_client_log
    ($xTargets, $xStart, $xEnd, $bChangedPaths
     , $bStrictNodeHistory, $crVisit, $self->{ctx}, $oPool);
}

sub log1_4 {
  my $self = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my ($xStart, $xEnd)      = _shiftRange(\@_, $xPeg);
  my $iVisitLimit          = _shiftInt(\@_);
  my $bChangedPaths        = _shiftBoolean(\@_);
  my $bStrictNodeHistory   = _shiftBoolean(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #omit the baton - despite it being included in the usage
  #statement, svn_client_log expects the $_[8] to be the context
  return SVN::_Client::svn_client_log3
    ($xTargets, $xPeg, $xStart, $xEnd, $iVisitLimit
     , $bChangedPaths, $bStrictNodeHistory, $crVisit
     , $self->{ctx}, $oPool);
}

sub log1_5 {
  my $self = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my ($xStart, $xEnd)      = _shiftRange(\@_, $xPeg);
  my $iVisitLimit          = _shiftInt(\@_);
  my $bChangedPaths        = _shiftBoolean(\@_);
  my $bStrictNodeHistory   = _shiftBoolean(\@_);
  my $bIncludeMergedRevisions = _shiftBoolean(\@_);
  my $aRevProps            = _shiftArray(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #omit the baton - despite it being included in the usage
  #statement, svn_client_log expects the $_[8] to be the context
  return SVN::_Client::svn_client_log4
    ($xTargets, $xPeg, $xStart, $xEnd, $iVisitLimit
     , $bChangedPaths, $bStrictNodeHistory
     , $bIncludeMergedRevisions, $aRevProps, $crVisit
     , $self->{ctx}, $oPool);
}


sub log1_6 {
  my $self = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $aRevRanges           = _shiftArray(\@_);
  my $iVisitLimit          = _shiftInt(\@_);
  my $bChangedPaths        = _shiftBoolean(\@_);
  my $bStrictNodeHistory   = _shiftBoolean(\@_);
  my $bIncludeMergedRevisions = _shiftBoolean(\@_);
  my $aRevProps            = _shiftArray(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #omit the baton - despite it being included in the usage
  #statement, svn_client_log expects the $_[8] to be the context
  return SVN::_Client::svn_client_log5
    ($xTargets, $xPeg, $aRevRanges, $iVisitLimit
     , $bChangedPaths, $bStrictNodeHistory
     , $bIncludeMergedRevisions, $aRevProps
     , $crVisit, $self->{ctx}, $oPool);
}

*log1_7 = *log1_6;

sub log {
  my $self = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  my ($xStart, $xEnd)      = _shiftRange(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $bChangedPaths        = _shiftBoolean(\@_);
  my $bStrictNodeHistory   = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #omit the baton - despite it being included in the usage
  #statement, svn_client_log expects the $_[6] to be the context
  return SVN::_Client::svn_client_log
    ($xTargets, $xStart, $xEnd, $bChangedPaths
     , $bStrictNodeHistory, $crVisit, $self->{ctx}, $oPool);
}

#----------------------------------------------------------------

sub ls1_1 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  SVN::_Client::svn_client_ls
    ($xTarget, $xPeg, $bRecurse, $self->{ctx}, $oPool);
}

sub list1_1 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  # Note: there is no equivalent to list in the 1.1 API so fake it

  my $hList = SVN::_Client::svn_client_ls
    ($xTarget, $xPeg, $bRecurse, $self->{ctx}, $oPool);
  return unless ref($hList);

  while (my ($k,$v) = each (%$hList)) {
    my $sFullPath = File::Spec->rel2abs($k,$xTarget);
    $crVisit->($k, $v, $sFullPath, $oPool);
  }
}

sub list1_4 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my ($xPeg,$xRev)         = _shiftPegRev(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $iFields              = _shiftListFieldMask(\@_);
  my $bFetchLocks          = _shiftBoolean(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  # Note: the 2007 release complains about "TypeError in method
  # 'svn_client_list', argument 7 of type 'svn_client_list_func_t'
  # Is this an error in the SWIG bindings?
  # Adding a baton parameter doesn't help.

  return SVN::_Client::svn_client_list
    ($xTarget, $xPeg, $xRev, $bRecurse, $iFields
     , $bFetchLocks, $crVisit, $self->{ctx}, $oPool);
}

sub list1_5 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my ($xPeg,$xRev)         = _shiftPegRev(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $iFields              = _shiftListFieldMask(\@_);
  my $bFetchLocks          = _shiftBoolean(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  # Note: the 2007 release complains about "TypeError in method
  # 'svn_client_list', argument 7 of type 'svn_client_list_func_t'
  # Is this an error in the SWIG bindings?
  # Adding a baton parameter doesn't help.

  return SVN::_Client::svn_client_list2
    ($xTarget, $xPeg, $xRev, $iDepth, $iFields
     , $bFetchLocks, $crVisit, $self->{ctx}, $oPool);
}

*list1_6 = *list1_5;
*list1_7 = *list1_5;

sub list {
  my ($self, $xTarget, $xPeg, $crVisit, $bRecurse) = @_;
  return $self->list1_1($xTarget, $xPeg, $bRecurse, $crVisit);
}

#----------------------------------------------------------------

sub merge1_1 {
  my $self                 = shift @_;
  my ($xTarget1, $xPeg1
      , $xTarget2, $xPeg2) = _shiftDiffTargets(\@_);
  my $sWc                  = _shiftWcPath(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bIgnoreAncestry      = _shiftBoolean(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $bDryRun              = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_merge
    ($xTarget1, $xPeg1, $xTarget2, $xPeg2, $sWc
     , $bRecurse, $bIgnoreAncestry, $bForce, $bDryRun
     , $self->{ctx}, $oPool);
}

sub merge1_4 {
  my $self                 = shift @_;
  my ($xTarget1, $xPeg1
      , $xTarget2, $xPeg2) = _shiftDiffTargets(\@_);
  my $sWc                  = _shiftWcPath(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bIgnoreAncestry      = _shiftBoolean(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $bDryRun              = _shiftBoolean(\@_);
  my $aMergeOptions        = _shiftArray(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  # 1.4.6 release complains about illegal parameter if
  # an array is passed in. We can work around this by
  # passing undef in place of an empty array, but other
  # parameters will fail.

  $aMergeOptions=undef if ! scalar(@$aMergeOptions);

  return SVN::_Client::svn_client_merge2
    ($xTarget1, $xPeg1, $xTarget2, $xPeg2, $sWc
     , $bRecurse, $bIgnoreAncestry, $bForce, $bDryRun
     , $aMergeOptions, $self->{ctx}, $oPool);
}


sub merge1_5 {
  my $self                 = shift @_;
  my ($xTarget1, $xPeg1
      , $xTarget2, $xPeg2) = _shiftDiffTargets(\@_);
  my $sWc                  = _shiftWcPath(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bIgnoreAncestry      = _shiftBoolean(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $bRecordOnly          = _shiftBoolean(\@_);
  my $bDryRun              = _shiftBoolean(\@_);
  my $aMergeOptions        = _shiftArray(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_merge3
    ($xTarget1, $xPeg1, $xTarget2, $xPeg2, $sWc
     , $iDepth, $bIgnoreAncestry, $bForce, $bRecordOnly, $bDryRun
     , $aMergeOptions, $self->{ctx}, $oPool);
}

*merge1_6 = *merge1_5;

sub merge1_7 {
  my $self                 = shift @_;
  my ($xTarget1, $xPeg1
      , $xTarget2, $xPeg2) = _shiftDiffTargets(\@_);
  my $sWc                  = _shiftWcPath(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bIgnoreAncestry      = _shiftBoolean(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $bRecordOnly          = _shiftBoolean(\@_);
  my $bDryRun              = _shiftBoolean(\@_);
  my $bAllowMixedRev       = _shiftBoolean(\@_);
  my $aMergeOptions        = _shiftArray(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_merge3
    ($xTarget1, $xPeg1, $xTarget2, $xPeg2, $sWc
     , $iDepth, $bIgnoreAncestry, $bForce, $bRecordOnly, $bDryRun
     , $bAllowMixedRev, $aMergeOptions, $self->{ctx}, $oPool);
}

*merge = *merge1_1;

#----------------------------------------------------------------

sub mkdir1_1 {
  my $self                 = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_mkdir
    ($xTargets, $self->{ctx}, $oPool);
}

sub mkdir1_4 {
  my $self                 = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_mkdir2
    ($xTargets, $self->{ctx}, $oPool);
}

sub mkdir1_5 {
  my $self                 = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bMakeParents         = _shiftBoolean(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_mkdir3
    ($xTargets, $bMakeParents, $hRevProps, $self->{ctx}, $oPool);
}

*mkdir1_6 = *mkdir1_5;

sub mkdir1_7 {
  my $self                 = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  local $LOG_MESSAGE       = _shiftString(\@_);
  my $bMakeParents         = _shiftBoolean(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $crCommit             = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_mkdir4
    ($xTargets, $bMakeParents, $hRevProps, $crCommit, $self->{ctx}
     , $oPool);
}

*mkdir=*mkdir1_1;

#----------------------------------------------------------------
# mod then move - requires force flag in 1.4 but not 1.5
# -see http://svn.haxx.se/users/archive-2008-07/0893.shtml

sub move1_1 {
  #note: the $xPeg parameter is ignored according to the SVN C/C++
  #API documentation

  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $xPeg                 = shift @_;
  my $xTo                  = _shiftTarget(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_move
    ($xTarget, $xPeg, $xTo, $bForce, $self->{ctx}, $oPool);
}

sub move1_4 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $sTo                  = _shiftTarget(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_move4
    ($xTarget, $sTo, $bForce, $self->{ctx}, $oPool);
}

sub move1_5 {
  my $self                 = shift @_;
  my $aTargets             = _shiftTargets(\@_);
  my $sTo                  = _shiftTarget(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $bMoveAsChild         = _shiftBoolean(\@_);
  my $bMakeParents         = _shiftBoolean(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_move5
    ($aTargets, $sTo, $bForce, $bMoveAsChild, $bMakeParents,
     $hRevProps, $self->{ctx}, $oPool);
}

*move1_6 = *move1_5;

sub move1_7 {
  my $self                 = shift @_;
  my $aTargets             = _shiftTargets(\@_);
  my $sTo                  = _shiftTarget(\@_);
  my $bMoveAsChild         = _shiftBoolean(\@_);
  my $bMakeParents         = _shiftBoolean(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $crCommit             = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_move6
    ($aTargets, $sTo, $bMoveAsChild, $bMakeParents,
     $hRevProps, $crCommit, $self->{ctx}, $oPool);
}

sub move {
  my $self                 = shift @_;
  my $sFrom                = _shiftTarget(\@_);
  my $sTo                  = _shiftTarget(\@_);
  my $bForce               = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #note: the $xPeg parameter is ignored according to the SVN C/C++
  #API documentation

  return SVN::_Client::svn_client_move
    ($sFrom, undef, $sTo, $bForce, $self->{ctx}, $oPool);
}

#----------------------------------------------------------------

sub propdel1_1 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propset
    ($sProp, undef, $xTarget, $bRecurse, $oPool);
}

sub propdel1_4 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propset2
    ($sProp, undef, $xTarget, $bRecurse, $bSkipChecks
    , $self->{ctx}, $oPool);
}

sub propde1_5 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $xBaseRev             = _shiftPeg(\@_,1);
  my $aChangeLists         = _shiftArray(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propset3
    ($sProp, undef, $xTarget, $iDepth, $bSkipChecks, $xBaseRev
     , $aChangeLists, $hRevProps, $self->{ctx}, $oPool);
}

*propdel1_6 = *propdel1_1;

sub propdel1_7 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $xBaseRev             = _shiftPeg(\@_,1);
  my $aChangeLists         = _shiftArray(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $crCommit             = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propset3
    ($sProp, undef, $xTarget, $iDepth, $bSkipChecks, $xBaseRev
     , $aChangeLists, $hRevProps, $crCommit, $self->{ctx}, $oPool);
}

sub propdel {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $sProp                = shift @_;
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propset
    ($sProp, undef, $xTarget, $bRecurse, $oPool);
}

#----------------------------------------------------------------

sub propget1_1 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_, 1);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propget
    ($sProp, $xTarget, $xPeg, $bRecurse, $self->{ctx}, $oPool);
}

sub propget1_4 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my ($xPeg,$xRev)         = _shiftPegRev(\@_, 1);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propget2
    ($sProp, $xTarget, $xPeg, $xRev, $bRecurse
     , $self->{ctx}, $oPool);
}

sub propget1_5 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my ($xPeg,$xRev)         = _shiftPegRev(\@_, 1);
  my $iDepth               = _shiftDepth(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propget2
    ($sProp, $xTarget, $xPeg, $xRev, $iDepth, $aChangeLists
     , $self->{ctx}, $oPool);
}

*propget1_6 = *propget1_5;
*propget1_7 = *propget1_5;

sub propget {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $sProp                = shift @_;
  my $xPeg                 = _shiftPeg(\@_, 1);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propget
    ($sProp, $xTarget, $xPeg, $bRecurse, $self->{ctx}, $oPool);
}

#----------------------------------------------------------------

sub proplist1_1 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_, 1);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_proplist
    ($xTarget, $xPeg, $bRecurse, $self->{ctx}, $oPool);
}

sub proplist1_4 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my ($xPeg,$xRev)         = _shiftPegRev(\@_, 1);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_proplist2
    ($xTarget, $xPeg, $xRev, $bRecurse, $self->{ctx}, $oPool);
}

sub proplist1_5 {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my ($xPeg,$xRev)         = _shiftPegRev(\@_, 1);
  my $iDepth               = _shiftDepth(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_proplist2
    ($xTarget, $xPeg, $xRev, $iDepth, $aChangeLists, $crVisit
    , $self->{ctx}, $oPool);
}

*proplist1_6 = *proplist1_5;
*proplist1_7 = *proplist1_5;
*proplist = *proplist1_1;

#----------------------------------------------------------------

sub propset1_1 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $sValue               = _shiftString(\@_);
  my $xTarget              = _shiftTarget(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propset
    ($sProp, $sValue, $xTarget, $bRecurse, $oPool);
}

sub propset1_4 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $sValue               = _shiftString(\@_);
  my $xTarget              = _shiftTarget(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propset2
    ($sProp, $sValue, $xTarget, $bRecurse, $bSkipChecks
     , $self->{ctx}, $oPool);
}

sub propset1_5 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $sValue               = _shiftString(\@_);
  my $xTarget              = _shiftTarget(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $xBaseRev             = _shiftPeg(\@_,1);
  my $aChangeLists         = _shiftArray(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propset3
    ($sProp, $sValue, $xTarget, $iDepth, $bSkipChecks, $xBaseRev
     , $aChangeLists, $hRevProps, $self->{ctx}, $oPool);
}

*propset1_6 = *propset1_5;

sub propset1_7 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $sValue               = _shiftString(\@_);
  my $xTarget              = _shiftTarget(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $xBaseRev             = _shiftPeg(\@_,1);
  my $aChangeLists         = _shiftArray(\@_);
  my $hRevProps            = _shiftHash(\@_);
  my $crCommit             = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propset3
    ($sProp, $sValue, $xTarget, $iDepth, $bSkipChecks, $xBaseRev
     , $aChangeLists, $hRevProps, $crCommit, $self->{ctx}, $oPool);
}

sub propset {
  my $self                 = shift @_;
  my $xTarget              = _shiftTarget(\@_);
  my $sProp                = shift @_;
  my $sValue               = _shiftString(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_propset
    ($sProp, $sValue, $xTarget, $bRecurse, $oPool);
}

#----------------------------------------------------------------

sub relocate1_1 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xFromRepos           = _shiftTarget(\@_);
  my $xToRepos             = _shiftTarget(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_relocate
    ($sWc, $xFromRepos, $xToRepos, $bRecurse, $self->{ctx}, $oPool);
}

*relocate1_4 = *relocate1_1;
*relocate1_5 = *relocate1_1;
*relocate1_6 = *relocate1_1;

sub relocate1_7 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xFromRepos           = _shiftTarget(\@_);
  my $xToRepos             = _shiftTarget(\@_);
  my $bIgnoreExternals     = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_relocate2
    ($sWc, $xFromRepos, $xToRepos, $bIgnoreExternals
    , $self->{ctx}, $oPool);
}

*relocate = *relocate1_1;

#----------------------------------------------------------------

sub resolved1_1 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_resolved
    ($sWc, $bRecurse, $self->{ctx}, $oPool);
}

*resolved1_4 = *resolved1_1;
*resolved1_5 = *resolved1_1;
*resolved1_6 = *resolved1_1;
*resolved1_7 = *resolved1_1;
*resolved    = *resolved1_1;

#----------------------------------------------------------------

sub revert1_1 {
  my $self                 = shift @_;
  my $aWcs                 = _shiftWcPaths(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_revert
    ($aWcs, $bRecurse, $self->{ctx}, $oPool);
}

*revert1_4 = *revert1_1;

sub revert1_5 {
  my $self                 = shift @_;
  my $aWcs                 = _shiftWcPaths(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_revert2
    ($aWcs, $iDepth, $aChangeLists, $self->{ctx}, $oPool);
}

*revert1_6 = *revert1_5;
*revert1_7 = *revert1_5;
*revert    = *revert1_1;

#----------------------------------------------------------------

sub revprop_delete1_1 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_revprop_set
    ($sProp, undef, $xRepos, $xPeg, $bSkipChecks
     , $self->{ctx}, $oPool);
}

*revprop_delete1_4 = *revprop_delete1_1;
*revprop_delete1_5 = *revprop_delete1_1;

sub revprop_delete1_6 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $sOldValue            = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_revprop_set2
    ($sProp, undef, $sOldValue, $xRepos, $xPeg, $bSkipChecks
     , $self->{ctx}, $oPool);
}

*revprop_delete1_7 = *revprop_delete1_6;


sub revprop_delete {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $sProp                = shift @_;
  my $xPeg                 = _shiftPeg(\@_);
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_revprop_set
    ($sProp, undef, $xRepos, $xPeg, $bSkipChecks
     , $self->{ctx}, $oPool);
}

#----------------------------------------------------------------

sub revprop_get1_1 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #the swig wrapper handles returning the value
  return SVN::_Client::svn_client_revprop_get
    ($sProp, $xRepos, $xPeg, $self->{ctx}, $oPool);
}

*revprop_get1_4 = *revprop_get1_1;
*revprop_get1_5 = *revprop_get1_1;
*revprop_get1_6 = *revprop_get1_1;
*revprop_get1_7 = *revprop_get1_1;

sub revprop_get {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $sProp                = shift @_;
  my $xPeg                 = _shiftPeg(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #the swig wrapper handles returning the value
  return SVN::_Client::svn_client_revprop_get
    ($sProp, $xRepos, $xPeg, $self->{ctx}, $oPool);

}

#----------------------------------------------------------------

sub revprop_list1_1 {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #the swig wrapper handles returning the value
  return SVN::_Client::svn_client_revprop_list
    ($xRepos, $xPeg, $self->{ctx}, $oPool);
}

*revprop_list1_4 = *revprop_list1_1;
*revprop_list1_5 = *revprop_list1_1;
*revprop_list1_6 = *revprop_list1_1;
*revprop_list1_7 = *revprop_list1_1;
*revprop_list    = *revprop_list1_1;


#----------------------------------------------------------------

sub revprop_set1_1 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $sValue               = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_revprop_set
    ($sProp, $sValue, $xRepos, $xPeg, $bSkipChecks
     , $self->{ctx}, $oPool);
}

*revprop_set1_4 = *revprop_set1_1;
*revprop_set1_5 = *revprop_set1_1;

sub revprop_set1_6 {
  my $self                 = shift @_;
  my $sProp                = shift @_;
  my $sValue               = shift @_;
  my $sOldValue            = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_revprop_set2
    ($sProp, $sValue, $sOldValue, $xRepos, $xPeg, $bSkipChecks
     , $self->{ctx}, $oPool);
}

*revprop_set1_7 = *revprop_set1_6;


sub revprop_set {
  my $self                 = shift @_;
  my $xRepos               = _shiftTarget(\@_);
  my $sProp                = shift @_;
  my $xPeg                 = _shiftPeg(\@_);
  my $sValue               = shift @_;
  my $bSkipChecks          = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_revprop_set
    ($sProp, $sValue, $xRepos, $xPeg, $bSkipChecks
     , $self->{ctx}, $oPool);
}

#--------------------------------------------------------------------

sub setConfig {
  my ($self, $xConfig) = @_;
  $xConfig = $CONFIG_CLASS->new($xConfig);
  return $self->{ctx}->config($xConfig->getCategoryHash());
}

#----------------------------------------------------------------

sub setPool {
  my ($self, $oPool) = @_;
  if (ref($oPool) !~ m{^_p_apr_pool_t|SVN::Pool$}) {
    die $EXCEPTIONS->ERR_BAD_ARG
      ->new(arg => $oPool, reason => "Pool must be undefined or "
            . "an SVN::Pool or _p_apr_pool_t object");
  }
  return $self->{pool} = $oPool;
}


#----------------------------------------------------------------

sub status1_1 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bAll                 = _shiftBoolean(\@_);
  my $bUpdate              = _shiftBoolean(\@_);
  my $bNoIgnore            = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  #Despite the fact that the usage string includes a status
  #baton, the actual method expects it to be omitted from the
  #parameter list

  return SVN::_Client::svn_client_status
    ($sWc, $xPeg, $crVisit, $bRecurse, $bAll
     , $bUpdate, $bNoIgnore, $self->{ctx}, $oPool);
}

sub status1_4 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bAll                 = _shiftBoolean(\@_);
  my $bUpdate              = _shiftBoolean(\@_);
  my $bNoIgnore            = _shiftBoolean(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_status2
    ($sWc, $xPeg, $crVisit, $bRecurse, $bAll, $bUpdate
    , $bNoIgnore, $bSkipExternals, $self->{ctx}, $oPool);
}

sub status1_5 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bAll                 = _shiftBoolean(\@_);
  my $bUpdate              = _shiftBoolean(\@_);
  my $bNoIgnore            = _shiftBoolean(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_status3
    ($sWc, $xPeg, $crVisit, $iDepth, $bAll, $bUpdate
    , $bNoIgnore, $bSkipExternals, $aChangeLists
    , $self->{ctx}, $oPool);
}

sub status1_6 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bAll                 = _shiftBoolean(\@_);
  my $bUpdate              = _shiftBoolean(\@_);
  my $bNoIgnore            = _shiftBoolean(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_status4
    ($sWc, $xPeg, $crVisit, $iDepth, $bAll, $bUpdate
    , $bNoIgnore, $bSkipExternals, $aChangeLists
    , $self->{ctx}, $oPool);
}

sub status1_7 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bAll                 = _shiftBoolean(\@_);
  my $bUpdate              = _shiftBoolean(\@_);
  my $bNoIgnore            = _shiftBoolean(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $aChangeLists         = _shiftArray(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_status5
    ($sWc, $xPeg, $iDepth, $bAll, $bUpdate
    , $bNoIgnore, $bSkipExternals, $aChangeLists
    , $crVisit, $self->{ctx}, $oPool);
}

sub status {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $crVisit              = _shiftVisitor(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bUpdate              = _shiftBoolean(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $bAll                 = _shiftBoolean(\@_);
  my $bNoIgnore            = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_status
    ($sWc, $xPeg, $crVisit, $bRecurse, $bAll
     , $bUpdate, $bNoIgnore, $self->{ctx}, $oPool);
}

#----------------------------------------------------------------

sub switch1_1 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xRepos               = _shiftTarget(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_switch
    ($sWc, $xRepos, $xPeg, $bRecurse, $self->{ctx}, $oPool);
}

*switch1_4 = *switch1_1;

sub switch1_5 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xRepos               = _shiftTarget(\@_);
  my ($xPeg, $xRev)        = _shiftPegRev(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bDepthIsSticky       = _shiftBoolean(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $bAllowUnversionedObstructions = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_switch
    ($sWc, $xRepos, $xPeg, $iDepth, $bDepthIsSticky, $bSkipExternals
     , $bAllowUnversionedObstructions, $self->{ctx}, $oPool);
}

*switch1_6 = *switch1_5;
*switch1_7 = *switch1_5;
*switch    = *switch1_1;

#----------------------------------------------------------------

sub unlock1_1 {
  my $self                 = shift @_;
  my $xTargets             = _shiftTargets(\@_);
  my $bBreakLock           = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_unlock
    ($xTargets, $bBreakLock, $self->{ctx}, $oPool);
}

*unlock1_4 = *unlock1_1;
*unlock1_5 = *unlock1_1;
*unlock1_6 = *unlock1_1;
*unlock1_7 = *unlock1_1;
*unlock = *unlock1_1;

#----------------------------------------------------------------

sub update1_1 {
  my $self                 = shift @_;
  my $sWc                  = _shiftWcPath(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_update
    ($sWc, $xPeg, $bRecurse, $self->{ctx}, $oPool);
}

sub update1_4 {
  my $self                 = shift @_;
  my $aWcs                 = _shiftWcPaths(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $bRecurse             = _shiftRecurse(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_update2
      ($aWcs, $xPeg, $bRecurse, $bSkipExternals
       , $self->{ctx}, $oPool);
}

sub update1_5 {
  my $self                 = shift @_;
  my $aWcs                 = _shiftWcPaths(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bDepthIsSticky       = _shiftBoolean(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $bAllowUnversionedObstructions = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_update3
      ($aWcs, $xPeg, $iDepth, $bDepthIsSticky
       , $bSkipExternals, $bAllowUnversionedObstructions
       , $self->{ctx}, $oPool);
}

*update1_6 = *update1_5;

sub update1_7 {
  my $self                 = shift @_;
  my $aWcs                 = _shiftWcPaths(\@_);
  my $xPeg                 = _shiftPeg(\@_);
  my $iDepth               = _shiftDepth(\@_);
  my $bDepthIsSticky       = _shiftBoolean(\@_);
  my $bSkipExternals       = _shiftBoolean(\@_);
  my $bAllowUnversionedObstructions = _shiftBoolean(\@_);
  my $bMakeParents         = _shiftBoolean(\@_);
  my $oPool                = $self->_shiftPool(\@_);

  return SVN::_Client::svn_client_update4
      ($aWcs, $xPeg, $iDepth, $bDepthIsSticky
       , $bSkipExternals, $bAllowUnversionedObstructions
       , $bMakeParents, $self->{ctx}, $oPool);
}

*update = *update1_1;

#----------------------------------------------------------------

#redefined here to make sure context is passed correctly:
#SVN::Client uses ref not isa when trying to decide whether it is
#being called as a function or as a method.

sub url_from_path {
  my ($self, $sWc, $oPool) = @_;

  $oPool = $self->{pool} unless defined($oPool);
  return SVN::_Client::svn_client_url_from_path($sWc, $oPool);
}

#----------------------------------------------------------------

#redefined here to make sure context is passed correctly:
#SVN::Client uses ref not isa when trying to decide whether it is
#being called as a function or as a method.

sub uuid_from_path {
  my ($self, $sWc, $oAdminAccess, $oPool) = @_;

  $oPool = $self->{pool} unless defined($oPool);
  unless ($oAdminAccess) {
    $oAdminAccess = SVN::_Wc::svn_wc_adm_probe_open3
    (undef, $sWc, 0, 0, undef, undef, $oPool);
  }

  return SVN::_Client::svn_client_uuid_from_path
    ($sWc, $oAdminAccess, $self->{ctx}, $oPool);
}

#----------------------------------------------------------------

#redefined here to make sure context is passed correctly:
#SVN::Client uses ref+eq not isa when trying to decide whether it is
#being called as a function or as a method.

sub uuid_from_url {
  my ($self, $xRepos, $oPool) = @_;

  $oPool = $self->{pool} unless defined($oPool);

  # quote repos name to force any "" override to convert an object
  # to a string
  return SVN::_Client::svn_client_uuid_from_url
    ("$xRepos", $self->{ctx}, $oPool);
}

#==================================================================
# PRIVATE OBJECT METHODS
#==================================================================

sub _shiftPool {
  my $self = shift @_;
  die "Not a $CLASS" unless $self->isa($CLASS);

  my $oPool = shift @{shift @_};
  return defined($oPool) ? $oPool : $self->{pool};
}

#==================================================================
# PRIVATE FUNCTIONS
#==================================================================

#sub _makeConfigActions($) {
#  my $hActions = shift @_;
#  my ($crNotify, $crLogMsg, $bLogMsgChange);

#  my $xCommit = $hActions->{commit};
#  if (ref($xCommit) eq 'HASH') {
#    if (exists($xCommit->{log_msg})) {
#      $bLogMsgChange = 1;
#      $crLogMsg = $xCommit->{log_msg};
#    }
#    $hActions->{commit} = $xCommit->{notify};
#  }
#  $crNotify = sub {
#    #my ($sPath, $iAction, $iKind, $sMime, $iState, $iRevision) = @_;
#    return _notifyFromHash($hActions, @_);
#  };
#  return ($crNotify, $crLogMsg, $bLogMsgChange);
#}

#----------------------------------------------------------------

sub _notifyAction($$@) {
  my $hNotify = shift @_;
  my $sKey = shift @_;
  my $sPath = shift @_;
  my $iAction = shift @_;
  my $crDefault = shift @_;

  my $xAction = exists($hNotify->{$sKey})
    ? $hNotify->{$sKey} : undef;

  my $sRef = ref($xAction);
  if ($sRef eq 'HASH') {
    my $crAction = exists($xAction->{$iAction})
      ? $xAction->{$iAction} : undef;

    return defined($crAction)
      ? $crAction->($sPath, $iAction, @_)
      : defined($crDefault)
         ? $crDefault->($sKey, $sPath, $iAction, @_)
         : undef; 

  } elsif ($sRef eq 'CODE') {
    return $xAction->($sPath, $iAction, @_);
  } elsif (defined($crDefault)) {
    $crDefault->($sKey, $sPath, $iAction, @_);
  } else {
    return undef;
  }
}

#----------------------------------------------------------------

sub _notifyFromHash($@) {
  my $hNotify = shift @_;
  my $sPath = shift @_;
  my $iAction = shift @_;
  my $crDefault;

  if (exists($hNotify->{default})) {
    $crDefault = $hNotify->{default};
    unshift @_, $crDefault;
  } else {
    unshift @_, undef;
  }

  #scheduled actions
  if ($iAction eq $SVN::Wc::Notify::Action::add) {
    return _notifyAction($hNotify, 'schedule', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::copy) {
    return _notifyAction($hNotify, 'schedule', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::delete) {
    return _notifyAction($hNotify, 'schedule', $sPath, $iAction, @_);
  }

  #revert actions
  if ($iAction eq $SVN::Wc::Notify::Action::restore) {
    return _notifyAction($hNotify, 'revert', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::revert) {
    return _notifyAction($hNotify, 'revert', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::failed_revert) {
    return _notifyAction($hNotify, 'revert', $sPath, $iAction, @_);
  }

  #resolved action
  if ($iAction eq $SVN::Wc::Notify::Action::resolved) {
    return _notifyAction($hNotify, 'resolved', $sPath, $iAction, @_);
  }

  #update actions
  if ($iAction eq $SVN::Wc::Notify::Action::skip) {
    return _notifyAction($hNotify, 'update', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::update_add) {
    return _notifyAction($hNotify, 'update', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::update_delete) {
    return _notifyAction($hNotify, 'update', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::update_update) {
    return _notifyAction($hNotify, 'update', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::update_external) {
    return _notifyAction($hNotify, 'update', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::update_completed) {
    return _notifyAction($hNotify, 'update', $sPath, $iAction, @_);
  }

  #follow
  if ($iAction eq $SVN::Wc::Notify::Action::status_external) {
    return _notifyAction($hNotify, 'follow', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::status_completed) {
    return _notifyAction($hNotify, 'follow', $sPath, $iAction, @_);
  }

  #commit actions
  if ($iAction eq $SVN::Wc::Notify::Action::commit_added) {
    return _notifyAction($hNotify, 'commit', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::commit_modified) {
    return _notifyAction($hNotify, 'commit', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::commit_deleted) {
    return _notifyAction($hNotify, 'commit', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::commit_replaced) {
    return _notifyAction($hNotify, 'commit', $sPath, $iAction, @_);
  } elsif ($iAction
           eq $SVN::Wc::Notify::Action::commit_postfix_txdelta) {
    return _notifyAction($hNotify, 'commit', $sPath, $iAction, @_);
  }

  #locking
  if ($iAction eq $SVN::Wc::Notify::Action::locked) {
    return _notifyAction($hNotify, 'lock', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::unlocked) {
    return _notifyAction($hNotify, 'lock', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::failed_lock) {
    return _notifyAction($hNotify, 'lock', $sPath, $iAction, @_);
  } elsif ($iAction eq $SVN::Wc::Notify::Action::failed_unlock) {
    return _notifyAction($hNotify, 'lock', $sPath, $iAction, @_);
  }

  #blame
  if ($iAction eq $SVN::Wc::Notify::Action::blame_revision) {
    return _notifyAction($hNotify, 'blame', $sPath, $iAction, @_);
  }


  if (1 <= $SVN::Core::VER_MAJOR) {
    if (5 <= $SVN::Core::VER_MINOR) {
      if ($iAction eq $SVN::Wc::Notify::Action::exists) {
        return _notifyAction($hNotify, 'schedule',$sPath,$iAction,@_);
      } elsif ($iAction
          eq $SVN::Wc::Notify::Action::changelist_set) {
        return _notifyAction($hNotify, 'schedule',$sPath,$iAction,@_);
      } elsif ($iAction
          eq $SVN::Wc::Notify::Action::changelist_clear) {
        return _notifyAction($hNotify, 'schedule',$sPath,$iAction,@_);
      } elsif ($iAction
          eq  $SVN::Wc::Notify::Action::changelist_moved) {
        return _notifyAction($hNotify, 'schedule',$sPath,$iAction,@_);
      } elsif ($iAction eq $SVN::Wc::Notify::Action::merge_begin) {
        return _notifyAction($hNotify, 'merge', $sPath, $iAction, @_);
      } elsif ($iAction
          eq $SVN::Wc::Notify::Action::foreign_merge_begin) {
        return _notifyAction($hNotify, 'merge', $sPath, $iAction, @_);
      } elsif ($iAction eq $SVN::Wc::Notify::Action::update_replace) {
        return _notifyAction($hNotify, 'update', $sPath, $iAction,@_);
      }
    }

    if (6 <= $SVN::Core::VER_MINOR) {
      if ($iAction eq $SVN::Wc::Notify::Action::property_added) {
        return _notifyAction($hNotify, 'schedule',$sPath,$iAction,@_);
      } elsif ($iAction
          eq $SVN::Wc::Notify::Action::property_modified) {
        return _notifyAction($hNotify, 'schedule',$sPath,$iAction,@_);
      } elsif ($iAction
          eq $SVN::Wc::Notify::Action::property_deleted) {
        return _notifyAction($hNotify, 'schedule',$sPath,$iAction,@_);
      } elsif ($iAction
          eq $SVN::Wc::Notify::Action::property_deleted_nonexistant) {
        return _notifyAction($hNotify, 'schedule',$sPath,$iAction,@_);
      } elsif ($iAction eq $SVN::Wc::Notify::Action::revprop_set) {
        return _notifyAction($hNotify, 'revprop',$sPath,$iAction,@_);
      } elsif ($iAction
          eq $SVN::Wc::Notify::Action::revprop_deleted) {
        return _notifyAction($hNotify, 'revprop',$sPath,$iAction,@_);
      } elsif ($iAction eq $SVN::Wc::Notify::Action::tree_conflict) {
        return _notifyAction($hNotify, 'update',$sPath,$iAction,@_);
      } elsif ($iAction eq $SVN::Wc::Notify::Action::merge_completed){
        return _notifyAction($hNotify, 'merge',$sPath,$iAction,@_);
      } elsif ($iAction eq $SVN::Wc::Notify::Action::failed_external){
        return _notifyAction($hNotify, 'follow',$sPath,$iAction,@_);
      }
    }

    if (7 <= $SVN::Core::VER_MINOR) {
      if ($iAction eq $SVN::Wc::Notify::Action::update_started) {
        return _notifyAction($hNotify, 'update',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::update_obstruction) {
        return _notifyAction($hNotify, 'update',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::update_external_removed) {
        return _notifyAction($hNotify, 'update',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::update_add_deleted) {
        return _notifyAction($hNotify, 'update',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::update_update_deleted) {
        return _notifyAction($hNotify, 'update',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::upgraded_path) {
        return _notifyAction($hNotify, 'update',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::merge_record_info) {
        return _notifyAction($hNotify, 'merge',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::merge_record_info_begin) {
        return _notifyAction($hNotify, 'merge',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::merge_elide_info) {
        return _notifyAction($hNotify, 'merge',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::patch) {
        return _notifyAction($hNotify, 'patch',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::patch_applied_hunk) {
        return _notifyAction($hNotify, 'patch',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::patch_rejected_hunk) {
        return _notifyAction($hNotify, 'patch',$sPath,$iAction,@_);
      } elsif ($iAction
         eq $SVN::Wc::Notify::Action::patch_hunk_already_applied) {
        return _notifyAction($hNotify, 'patch',$sPath,$iAction,@_);
      } elsif ($iAction eq $SVN::Wc::Notify::Action::url_redirect) {
        return _notifyAction($hNotify, 'follow',$sPath,$iAction,@_);
      }
    }
  }

  if (defined($crDefault)) {
    shift @_;  #get rid of $crDefault at the front
    return $crDefault->(undef, $sPath, $iAction, @_);
  } else {
    return undef;
  }
}

#----------------------------------------------------------------

sub _shiftArray {
  my $xArg = shift @{shift @_};
  return defined($xArg) ? $xArg : [];
}

#----------------------------------------------------------------

sub _shiftDiffTargets($) {
  my $aArgs = shift @_;
  my $xTarget1 = shift @$aArgs;
  my $xPeg1 = shift  @$aArgs;
  my $xTarget2 = shift  @$aArgs;
  my $xPeg2 = shift  @$aArgs;

  if (defined($xTarget1)) {
    $xTarget1 = "$xTarget1";
  } else {
    $xTarget1 = File::Spec->curdir();
  }
  $xTarget2 = defined($xTarget2) ? "$xTarget2" : $xTarget1;

  if ($xTarget1 ne $xTarget2) {
    if (defined($xPeg1)) {
      $xPeg2 = $xPeg1 unless defined($xPeg2);
    } elsif (defined($xPeg2)) {
      $xPeg1 = $xPeg2 unless defined($xPeg1);
    } else {
      $xPeg1 = $xPeg2 = 'BASE';
    }
  } elsif (defined($xPeg1)) {
    if (Scalar::Util::looks_like_number($xPeg1)) {
      $xPeg2 = $xPeg1 + 1;
    } elsif ($xPeg1 eq 'PREV') {
      $xPeg2 = 'COMMITTED';
    } elsif ($xPeg1 =~ qr{BASE|HEAD|COMMITTED}) {
      $xPeg2 = 'WORKING';
    } else {
      $xPeg2 = $xPeg1;
    }
  } elsif (defined($xPeg2)) {
    if (Scalar::Util::looks_like_number($xPeg2)) {
      $xPeg1 = $xPeg2 - 1;
    } elsif ($xPeg2 eq 'COMMITTED') {
      $xPeg1 = 'PREV';
    } elsif ($xPeg2 eq 'WORKING') {
      $xPeg1 = 'BASE';
    } else {
      $xPeg1 = $xPeg2;
    }
  } else {
    $xPeg1 = 'BASE';
    $xPeg2 = 'WORKING';
  }

  # WORKING isn't listed in SVN documentation nor in the C code for
  # converting strings to svn_opt_revision_t instances. It seems to
  # be SWIG's way of representing svn_opt_revision_t without having
  # to create a whole struct for it. SWIG auto-translates this to
  # the right sort of object instance - see line 1172 in
  # http://svn.apache.org/viewvc/subversion/trunk/subversion/bindings/swig/include/svn_types.swg

  #print STDERR "<$xTarget1> <$xPeg1> <$xTarget2> <$xPeg2>\n";

  return ($xTarget1, $xPeg1, $xTarget2, $xPeg2);
}

#----------------------------------------------------------------

sub _shiftErrFile($) {
  my $xArg = shift @{shift @_};
  return defined($xArg) ? $xArg : \*STDERR;
}

#----------------------------------------------------------------

sub _shiftDepth {
  my $xArg = shift @{shift @_};
  return defined($xArg) ? $xArg : $SVN::Depth::infinity;
}

#----------------------------------------------------------------

sub _shiftHash {
  my $xArg = shift @{shift @_};
  return defined($xArg) ? $xArg : {};
}

#----------------------------------------------------------------

sub _shiftInt {
  my $xArg = shift @{shift @_};
  return defined($xArg) ? $xArg : 0;
}

#----------------------------------------------------------------

sub _shiftListFieldMask($) {
  my $xArg = shift @{shift @_};
  return defined($xArg) ? $xArg : $SVN::Friendly::List::Fields::ALL;
}

#----------------------------------------------------------------

sub _shiftOutFile {
  my $xArg = shift @{shift @_};
  return defined($xArg) ? $xArg : \*STDOUT;
}

#----------------------------------------------------------------

sub _shiftOutputEncoding {
  my $xArg = shift @{shift @_};
  if (defined($xArg)) {
    return $xArg;
  } else {
    return defined($xArg) ? $xArg : $SVN::_Core::svn_locale_charset;
  }
}

#----------------------------------------------------------------

sub _shiftOutputEol($) {
  # $sNativeEol may be 'CR', 'LF', 'CRLF', undef
  # undef is platform EOL

  my $xArg = shift @{shift @_};
  return $xArg;
}

#----------------------------------------------------------------

sub _shiftPegRev {
  my ($aArgs, $bUndefIsWorking) = @_;
  my ($xPeg, $xRev);
  unless (ref($aArgs->[0])) {
    $xPeg = shift @$aArgs;
    $xRev = shift(@$aArgs) unless (ref($aArgs->[0]));
  }

  if (!defined($xPeg)) {
    $xPeg = $bUndefIsWorking ? 'WORKING' : 'HEAD';
  }
  $xRev = $xPeg unless defined($xRev);
  return ($xPeg, $xRev);
}

#----------------------------------------------------------------

sub _shiftPeg {
  my ($aArgs, $bUndefIsWorking) = @_;
  my $xPeg = shift(@$aArgs) unless (ref($aArgs->[0]));
  if (!defined($xPeg) || ($xPeg eq '')) {
    $xPeg = $bUndefIsWorking ? 'WORKING' : 'HEAD';
  }
  return $xPeg;
}

#----------------------------------------------------------------

sub _shiftRecurse {
  my $xArg = shift @{shift @_};
  return defined($xArg) ? $xArg : 1;
}

#----------------------------------------------------------------

sub _shiftRange {
  my ($aArgs, $xMax) = @_;
  $xMax = 'HEAD' unless defined($xMax);

  my ($xStart, $xEnd);
  unless (ref($aArgs->[0])) {
    $xStart = shift @$aArgs;
    $xEnd = shift(@$aArgs) unless (ref($aArgs->[0]));
  }
  $xStart = 0 unless defined($xStart);
  $xEnd = $xMax unless defined($xEnd);
  return ($xStart, $xEnd);
}

#----------------------------------------------------------------

sub _shiftTarget {
  my $xArg = shift @{shift @_};

  # quote the value to force any overridden "" operator to
  # convert this into a string
  return defined($xArg) ? "$xArg" : undef;
}

#----------------------------------------------------------------

sub _shiftTargets {
  my $xTargets = shift @{shift @_};

  my $sRef = ref($xTargets);
  #print STDERR "_shiftTargets: <$xTargets> <$sRef>\n";

  if ($sRef eq 'ARRAY') {
    foreach (@$xTargets) { $_ = "$_"; }
  } elsif (defined($xTargets)) {
    $xTargets = [ "$xTargets" ]; #force overridden ""
  } else {
    return [];
  }
  return $xTargets;
}

#----------------------------------------------------------------

sub _shiftString {
  my $xArg = shift @{shift @_};
  return defined($xArg) ? $xArg : '';
}

#----------------------------------------------------------------

sub _shiftTrue {
  my $xArg = shift @{shift @_};
  return defined($xArg) ? $xArg : 1;
}

##----------------------------------------------------------------
## Most likely not needed - if thunk is defined, no need for baton,
## if thunk is not defined, there is nothing we can do to make it
## work without changing the source code and recompiling the
## C-Bindings.

#sub _shiftVisitorBaton {
#  my ($aArgs) = @_;

#  my $crVisit = _shiftVisitor($aArgs);
#  my $xBaton = shift @$aArgs;
#  return ($crVisit, $xBaton);
#}

#----------------------------------------------------------------

sub _shiftWcPath {
  my $xArg = shift @{shift @_};
  #return defined($xArg) ? $xArg : $SYSTEM->cwd();
  return defined($xArg) ? $xArg : File::Spec->curdir();
}

#----------------------------------------------------------------

sub _shiftWcPaths($) {
  my $aWcs = shift @{shift @_};
  return [] unless defined($aWcs);
  return ref($aWcs) ? $aWcs : [ $aWcs ];
}

#==================================================================
# MODULE INITIALIZATION
#==================================================================

1;
