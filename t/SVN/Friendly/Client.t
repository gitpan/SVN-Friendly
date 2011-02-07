use strict;
use warnings;
use Test::More tests=>2146;

#------------------------------------------------------------------

BEGIN { use_ok('SVN::Friendly::Client') or BAIL_OUT; };
my $TEST_CLASS = "SVN::Friendly::Client";
my $CLIENT_CLASS = $TEST_CLASS;
my $CONFIG_CLASS = 'SVN::Friendly::Config';

use SVN::Friendly::Utils;

#------------------------------------------------------------------
# Capabilities and known bugs
# Note: this should be reevaluated from time to time
#------------------------------------------------------------------

my $SKIP_SWIG_BUGS=1;
my $NAG_REPORT_SWIG_BUGS=1;
my %SWIG_BINDING_BUGS;

my @VERSION_SUFFIXES=('', qw(1_1 1_4 1_5 1_6 1_7));
my $IDX_SVN1_4  = 2;
my $IDX_SVN1_7  = $IDX_SVN1_4 + 3;
my $WC_LAST_IDX = $IDX_SVN1_4;

sub isBeforeOrAtRelease {
  return ($SVN::Core::VER_MAJOR <= $_[0]) && ($SVN::Core::VER_MINOR <= $_[1]);
}

# remote setting of properties is not supported before 1.7
my $IDX_REMOTE_PROPSET = $IDX_SVN1_7;

#------------------------------------------------------------------
#------------------------------------------------------------------

use Exception::Lite;
Exception::Lite::onDie(4);

# This lets us catch unexpected warnings and trigger a fail event
local $SIG{__WARN__} = sub {
  my $sWarning = shift @_;
  ok(0, "No warnings");
  diag($sWarning);
};

#------------------------------------------------------------------

use URI::file;

#------------------------------------------------------------------

use Test::New qw(testNew);
use Test::Sandbox qw(makeSandbox);

my $SANDBOX_CLASS = 'Test::Sandbox';
my $SANDBOX = $SANDBOX_CLASS->new($TEST_CLASS);
my $IMPORT_DIR = $SANDBOX->addDir();
my $IMPORT_TREE
  = { (map {$_=>1} qw(A/ A/B1/  A/B2/  A/B1/C1/  A/B1/C2/))
      , 'X.txt' => 'This is an X file'
      , 'A/Y.txt' => "This is data for A/Y.txt"
      , 'A/B1/Z.dat' => "Data for A/B1/Z.dat"
    };
my $IMPORT_PATHS = $SANDBOX->addPaths($IMPORT_DIR, $IMPORT_TREE);
my $IMPORT_LISTING = [ map { /^(.+)\/$/ ? $1 : $_
                           } keys %$IMPORT_TREE ];

#------------------------------------------------------------------

use SVN::Core;
use SVN::Friendly::Client;
use SVN::Friendly::Repos;
my $REPO_CLASS='SVN::Friendly::Repos';

my $UNVERSIONED_STATUS
  = { text_status => $SVN::Wc::Status::unversioned
      , prop_status => $SVN::Wc::Status::none
      , locked => 0
      , copied => 0
      , switched => 0
      , repos_text_status => $SVN::Wc::Status::none
      , repos_prop_status => $SVN::Wc::Status::none
    };

my $ADD_STATUS
  = { text_status => $SVN::Wc::Status::added
      , prop_status => $SVN::Wc::Status::none
      , locked => 0
      , copied => 0
      , switched => 0
      , repos_text_status => $SVN::Wc::Status::none
      , repos_prop_status => $SVN::Wc::Status::none
    };
my $COPY_STATUS
  = { text_status => $SVN::Wc::Status::added
      , prop_status => $SVN::Wc::Status::none
      , locked => 0
      , copied => 1
      , switched => 0
      , repos_text_status => $SVN::Wc::Status::none
      , repos_prop_status => $SVN::Wc::Status::none
    };
my $NORMAL_STATUS
  = { text_status => $SVN::Wc::Status::normal
      , prop_status => $SVN::Wc::Status::none
      , locked => 0
      , copied => 0
      , switched => 0
      , repos_text_status => $SVN::Wc::Status::none
      , repos_prop_status => $SVN::Wc::Status::none
    };

# subversion 1.5 adds a svn:mergeinfo property to copied files
my $NORMAL_COPY_STATUS = { %$NORMAL_STATUS };
$NORMAL_COPY_STATUS->{prop_status} = $SVN::Wc::Status::normal
  unless isBeforeOrAtRelease(1,4);


my $NORMAL_LOCK_STATUS
  = { text_status => $SVN::Wc::Status::normal
      , prop_status => $SVN::Wc::Status::none
      , locked => 1
      , copied => 0
      , switched => 0
      , repos_text_status => $SVN::Wc::Status::none
      , repos_prop_status => $SVN::Wc::Status::none
    };
my $NORMAL_PROP_STATUS
  = { text_status => $SVN::Wc::Status::normal
      , prop_status => $SVN::Wc::Status::normal
      , locked => 0
      , copied => 0
      , switched => 0
      , repos_text_status => $SVN::Wc::Status::none
      , repos_prop_status => $SVN::Wc::Status::none
    };
my $MOD_PROP_STATUS
  = { text_status => $SVN::Wc::Status::normal
      , prop_status => $SVN::Wc::Status::modified
      , locked => 0
      , copied => 0
      , switched => 0
      , repos_text_status => $SVN::Wc::Status::none
      , repos_prop_status => $SVN::Wc::Status::none
    };

my $DEL_STATUS
  = { text_status => $SVN::Wc::Status::deleted
      , prop_status => $SVN::Wc::Status::none
      , locked => 0
      , copied => 0
      , switched => 0
      , repos_text_status => $SVN::Wc::Status::none
      , repos_prop_status => $SVN::Wc::Status::none
    };
my $NOT_FOUND_STATUS
  = { text_status => $SVN::Wc::Status::none
      , prop_status => $SVN::Wc::Status::none
      , locked => 0
      , copied => 0
      , switched => 0
      , repos_text_status => $SVN::Wc::Status::none
      , repos_prop_status => $SVN::Wc::Status::none
    };

#-------------------------------------------------------------------
# Notification action monitoring
#-------------------------------------------------------------------

our $NOISY = 0;

sub okNotifyActions(&$$;$);
my @aNotifications;
my $NOTIFYING;
my $IDX_NOTIFY_ACTION = 0;
my $SOME_STRING_EXCEPTION='';


sub testNotify {
  my $sPath = shift @_;
  my ($iAction, $iKind, $sMime, $iState, $iRevision) = @_;
  push @aNotifications, \@_;

  if ($NOISY) {
    my $sState = defined($iState)
      ? $CLIENT_CLASS->getStateAsString($iState) : '';
    print STDERR "doing... action=<"
      . $CLIENT_CLASS->getActionAsString($iAction)
      . ">, state=<$sState>, revision=<$iRevision>, path=<$sPath>"
      . ", kind=<$iKind>\n";
  }
  return 0;
}

#---------------------------------------
# scheduled actions

my $ADD_ACTIONS  = [ $SVN::Wc::Notify::Action::add ];
my $DEL_ACTIONS  = [ $SVN::Wc::Notify::Action::delete ];

# for some reason the expected action after a copy is add,
# not copy.

my $COPY_ACTIONS = [ $SVN::Wc::Notify::Action::add ];

# this is for moving a single file or empty directory. If the
# directory is non-empty there will be a delete action for the
# directory and each of its members

my $MOVE_ACTIONS = [ $SVN::Wc::Notify::Action::add
                     , $SVN::Wc::Notify::Action::delete
                   ];

my $REVERT_ACTIONS
  = [ $SVN::Wc::Notify::Action::revert ];

#---------------------------------------
# synchronization actions

my $UPDATE_ACTIONS = [ $SVN::Wc::Notify::Action::update_update
                       , $SVN::Wc::Notify::Action::update_completed
                     ];

my $DEL_COMMIT_ACTIONS
  = [ $SVN::Wc::Notify::Action::commit_deleted ];

my $COPY_COMMIT_ACTIONS
  = [ $SVN::Wc::Notify::Action::commit_added ];

my $MOVE_COMMIT_ACTIONS
  = [ $SVN::Wc::Notify::Action::commit_deleted
      , $SVN::Wc::Notify::Action::commit_added
    ];
my $MOD_COMMIT_ACTIONS
  = [ $SVN::Wc::Notify::Action::commit_modified ];

# The constants below are for a committing a single file or empty
# directory.  Multiple files and non-empty directories will have
# additional add actions.  When committing files, subversion sends
# a list of all the planned actions to the repository first, one
# for each file or dir to be added. Then if there are no show
# stoppers, then and only then does it send the text of any files
# that have been added or modified (commit_postfix_txdelta). See
# http://svn.apache.org/repos/asf/subversion/trunk/notes/subversion-design.html

my $ADD_DIR_COMMIT_ACTIONS
  = [ $SVN::Wc::Notify::Action::commit_added ];

my $ADD_FILE_COMMIT_ACTIONS
  = [ $SVN::Wc::Notify::Action::commit_added
      , $SVN::Wc::Notify::Action::commit_postfix_txdelta];

my $LOCK_FILE_ACTIONS
  = [ $SVN::Wc::Notify::Action::locked ];

my $UNLOCK_FILE_ACTIONS
  = [ $SVN::Wc::Notify::Action::unlocked ];

#---------------------------------------
# merge and diff actions

my $MERGE_ACTIONS = [ $SVN::Wc::Notify::Action::update_update];


#==================================================================
# TEST SUITES
#==================================================================

sub testDefaults {
  my $sName;

  #_shiftArray
  $sName = '_shiftArray';
  okShift1($sName
           , \&SVN::Friendly::Client::_shiftArray, undef, []);
  okShift1($sName
           , \&SVN::Friendly::Client::_shiftArray, [1,2,3], [1,2,3]);

  #_shiftBoolean
  $sName = '_shiftBoolean';
  okShift1($sName, \&SVN::Friendly::Utils::_shiftBoolean, undef, 0);
  okShift1($sName, \&SVN::Friendly::Utils::_shiftBoolean, 0, 0);
  okShift1($sName, \&SVN::Friendly::Utils::_shiftBoolean, 1, 1);

  #_shiftDiffTargets
  $sName = '_shiftDiffTargets';
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , [undef,undef, undef, undef]
              , [File::Spec->curdir(), 'BASE'
                  , File::Spec->curdir(), 'WORKING']);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , ['a', undef, undef, undef]
              , ['a', 'BASE', 'a', 'WORKING']);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , ['a','WORKING', undef, undef]
              , ['a', 'WORKING', 'a', 'WORKING']);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , ['a', undef, undef, undef]
              , ['a','BASE','a', 'WORKING']);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , ['a', undef, undef, 'COMMITTED']
              , ['a', 'PREV', 'a', 'COMMITTED']);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , ['a', undef, undef, 'WORKING']
              , ['a', 'BASE', 'a', 'WORKING']);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , ['a', undef, undef, 5]
              , ['a', 4, 'a', 5]);

  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , ['a','HEAD', undef, undef]
              , ['a', 'HEAD', 'a', 'WORKING']);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , ['a','BASE', undef, undef]
              , ['a', 'BASE', 'a', 'WORKING']);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , ['a','COMMITTED', undef, undef]
              , ['a', 'COMMITTED', 'a', 'WORKING']);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , ['a','PREV', undef, undef]
              , ['a', 'PREV', 'a', 'COMMITTED']);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftDiffTargets
              , ['a', 0, undef, undef]
              , ['a', 0, 'a', 1]);

  #_shiftDepth
  $sName = '_shiftDepth';
  okShift1($sName, \&SVN::Friendly::Client::_shiftDepth
           , undef, $SVN::Depth::infinity);
  okShift1($sName, \&SVN::Friendly::Client::_shiftDepth
           , $SVN::Depth::infinity, $SVN::Depth::infinity);
  okShift1($sName, \&SVN::Friendly::Client::_shiftDepth
           , $SVN::Depth::empty, $SVN::Depth::empty);

  #_shiftErrFile
  $sName = '_shiftErrFile';
  okShift1($sName, \&SVN::Friendly::Client::_shiftErrFile
           , undef, \*STDERR);
  okShift1($sName, \&SVN::Friendly::Client::_shiftErrFile
           , \*STDERR, \*STDERR);
  okShift1($sName, \&SVN::Friendly::Client::_shiftErrFile
           , \*STDOUT, \*STDOUT);
  okShift1($sName, \&SVN::Friendly::Client::_shiftErrFile
           , 'foo', 'foo');

  #_shiftHash
  $sName = '_shiftHash';
  okShift1($sName
           , \&SVN::Friendly::Client::_shiftHash, undef, {});
  okShift1($sName
           , \&SVN::Friendly::Client::_shiftHash, {a=>1}, {a=>1});

  #_shiftInt
  $sName = '_shiftInt';
  okShift1($sName, \&SVN::Friendly::Client::_shiftInt, undef, 0);
  okShift1($sName, \&SVN::Friendly::Client::_shiftInt, 1, 1);
  okShift1($sName, \&SVN::Friendly::Client::_shiftInt, 0, 0);
  okShift1($sName, \&SVN::Friendly::Client::_shiftInt, -1, -1);

  #_shiftListFieldMask
  $sName = '_shiftListFieldMask';
  okShift1($sName, \&SVN::Friendly::Client::_shiftListFieldMask
           , undef, $SVN::Friendly::List::Fields::ALL);
  okShift1($sName, \&SVN::Friendly::Client::_shiftListFieldMask
           , $SVN::Friendly::List::Fields::ALL
           , $SVN::Friendly::List::Fields::ALL);
  okShift1($sName, \&SVN::Friendly::Client::_shiftListFieldMask
           , $SVN::Friendly::List::Fields::LAST_AUTHOR
           , $SVN::Friendly::List::Fields::LAST_AUTHOR);


  #_shiftOutFile
  $sName = '_shiftOutFile';
  okShift1($sName, \&SVN::Friendly::Client::_shiftOutFile
           , undef, \*STDOUT);
  okShift1($sName, \&SVN::Friendly::Client::_shiftOutFile
           , \*STDERR, \*STDERR);
  okShift1($sName, \&SVN::Friendly::Client::_shiftOutFile
           , \*STDOUT, \*STDOUT);
  okShift1($sName, \&SVN::Friendly::Client::_shiftOutFile
           , 'foo', 'foo');

  #_shiftOutputEncoding
  $sName = '_shiftOutputEncoding';
  my $sDefault = $SVN::_Core::svn_locale_charset;

  okShift1($sName, \&SVN::Friendly::Client::_shiftOutputEncoding
           , undef, $sDefault);
  okShift1($sName, \&SVN::Friendly::Client::_shiftOutputEncoding
           , 'UTF-8', 'UTF-8');

  #_shiftOutputEol
  $sName = '_shiftOutputEol';
  okShift1($sName, \&SVN::Friendly::Client::_shiftOutputEol
           , undef, undef);
  okShift1($sName, \&SVN::Friendly::Client::_shiftOutputEol
           , 'CRLF', 'CRLF');
  okShift1($sName, \&SVN::Friendly::Client::_shiftOutputEol
           , 'LF', 'LF');

  #_shiftPegRev
  $sName = '_shiftPegRev';
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftPegRev
              , [undef,undef], ['HEAD','HEAD'], 1);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftPegRev
              , ['COMMITTED',undef], ['COMMITTED','COMMITTED'], 1);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftPegRev
              , [1,'COMMITTED'], [1,'COMMITTED'], 1);

  #_shiftPeg
  $sName = '_shiftPeg';
  okShift1($sName, \&SVN::Friendly::Client::_shiftPeg, undef, 'HEAD');
  okShift1($sName, \&SVN::Friendly::Client::_shiftPeg, 'PREV', 'PREV');

  #_shiftRecurse
  $sName = '_shiftRecurse';
  okShift1($sName, \&SVN::Friendly::Client::_shiftRecurse, undef, 1);
  okShift1($sName, \&SVN::Friendly::Client::_shiftRecurse, 0, 0);
  okShift1($sName, \&SVN::Friendly::Client::_shiftRecurse, 1, 1);

  #_shiftRange
  $sName = '_shiftRange';
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftRange
              , [undef,undef], [0,'HEAD'], 1);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftRange
              , ['PREV',undef], ['PREV','HEAD'], 1);
  okShiftMany($sName, \&SVN::Friendly::Client::_shiftRange
              , [3,47], [3,47], 1);

  #_shiftTarget
  my $oURI = URI->new('http://www.example.com');
  $sName = '_shiftTarget';
  okShift1($sName, \&SVN::Friendly::Client::_shiftTarget
           , undef, undef);
  okShift1($sName, \&SVN::Friendly::Client::_shiftTarget
           , 'a', 'a');
  okShift1($sName, \&SVN::Friendly::Client::_shiftTarget
           , $oURI, $oURI->as_string());

  #_shiftTargets
  $sName = '_shiftTargets';
  okShift1($sName, \&SVN::Friendly::Client::_shiftTargets
           , undef, []);
  okShift1($sName, \&SVN::Friendly::Client::_shiftTargets
           , 'a', ['a']);
  okShift1($sName, \&SVN::Friendly::Client::_shiftTargets
           , ['a'], ['a']);
  okShift1($sName, \&SVN::Friendly::Client::_shiftTargets
           , $oURI, [ $oURI->as_string() ]);
  okShift1($sName, \&SVN::Friendly::Client::_shiftTargets
           , [$oURI], [ $oURI->as_string() ]);

  #_shiftString
  $sName = '_shiftString';
  okShift1($sName, \&SVN::Friendly::Client::_shiftString, undef, '');
  okShift1($sName, \&SVN::Friendly::Client::_shiftString, 'a', 'a');

  #_shiftTrue
  $sName = '_shiftTrue';
  okShift1($sName, \&SVN::Friendly::Client::_shiftTrue, undef, 1);
  okShift1($sName, \&SVN::Friendly::Client::_shiftTrue, 0, 0);
  okShift1($sName, \&SVN::Friendly::Client::_shiftTrue, 1, 1);

  #_shiftVisitor
  my $crSub = sub {};
  okShift1($sName, \&SVN::Friendly::Utils::_shiftVisitor
           , undef, $SVN::Friendly::Utils::NOOP);
  okShift1($sName, \&SVN::Friendly::Utils::_shiftVisitor
           , $crSub, $crSub);

#  #_shiftVisitorBaton
#  $sName = '_shiftVisitor';
#  okShiftMany($sName, \&SVN::Friendly::Client::_shiftVisitorBaton
#              , [undef,undef], [$SVN::Friendly::Client::NOOP, undef]);
#  okShiftMany($sName, \&SVN::Friendly::Client::_shiftVisitorBaton
#              , [$crSub,undef], [$crSub, undef]);
#  okShiftMany($sName, \&SVN::Friendly::Client::_shiftVisitorBaton
#              , [$crSub,'a'], [$crSub, 'a']);

  #_shiftWcPath
  $sName = '_shiftWcPath';
  okShift1($sName, \&SVN::Friendly::Client::_shiftWcPath
           , undef, File::Spec->curdir());
  okShift1($sName, \&SVN::Friendly::Client::_shiftWcPath
           , 'a', 'a');

  #_shiftWcPaths
  $sName = '_shiftWcPaths';
  okShift1($sName, \&SVN::Friendly::Client::_shiftWcPaths
           , undef, []);
  okShift1($sName, \&SVN::Friendly::Client::_shiftWcPaths
           , 'a', ['a']);
  okShift1($sName, \&SVN::Friendly::Client::_shiftWcPaths
           , ['a'], ['a']);
}

#--------------------------------------------------------------------

sub testClient_Local_NoAuth {
  my ($sName, $oClient, $aaParams, $hProperties);

  # client with notifications ($crNotify = \&testNotify

  $NOTIFYING=1;
  $sName = 'local_NoAuth_notify';
  $aaParams = [[ undef, undef, \&testNotify ]
               , [ undef, undef, \&testNotify, undef ]
               , [ undef, undef, \&testNotify, undef, undef ]
               , [ undef, undef, \&testNotify, undef, undef, undef ]
              ];

  $hProperties = { getNotificationCallback => \&testNotify
                   , getLogMessageCallback => undef
                   , getCancellationCallback => undef
                 };

  $oClient = testNewClient($sName, $aaParams, $hProperties);

  #DEBUG - START
  #testAuthentication($sName, $oClient);
  #exit(); #STOP_TESTING
  #DEBUG - END

  testWc($sName, $oClient, 1);

  # do configuration tests _after_ testWc so that testWc uses
  # the configuration set up by testNewClient

  testNotification($sName, $oClient);
  testAuthentication($sName, $oClient);
  is(ref($oClient->getConfig()), $CONFIG_CLASS
    , "$sName - verifying config object");

  # client without notifications ($crNotify = undef)

  $NOTIFYING=0;
  $sName = 'local_NoAuth';
  $aaParams = [[]
               ,[undef]
               ,[undef,undef]
               ,[undef,undef,undef]
               ,[undef,undef,undef,undef]
               ,[undef,undef,undef,undef, undef]
               ,[undef,undef,undef,undef, undef, undef]
              ];

  $hProperties = { getNotificationCallback => undef
                   , getLogMessageCallback => undef
                   , getCancellationCallback => undef
                 };

  $oClient = testNewClient($sName, $aaParams, $hProperties);
  testWc($sName, $oClient, 0);

}

#==================================================================
# UTILITIES
#==================================================================

#--------------------------------------------------------------------

sub _appendRelPathToURL {
  my ($sURL, $sRelPath) = @_;

  # use local file system rules for "file" protocol.
  # for others (http, https, ftp, svn+ssh) assume POSIX path syntax

  return $sURL  =~ m{^file://(.*)$}
    ? 'file://' . File::Spec->rel2abs($sRelPath, $1)
    : "$sURL/$sRelPath";
}


#--------------------------------------------------------------------

sub _isMinimal {
  my $aParams = shift;
  return 0 if scalar(@$aParams);

  for (@_) { return 0 if defined($_) }
  return 1;
}

#--------------------------------------------------------------------

sub _selectPaths {
  my ($aPaths, $iStart, $iEnd) = @_;
  $iEnd = $iStart unless defined($iStart);
  return [ (undef) x $iStart, @$aPaths[$iEnd..$iStart] ];
}

#==================================================================
# SUBTESTS
#==================================================================

#--------------------------------------------------------------------

sub okAdd {
  my ($sName, $oClient, $aPaths, $aCreate, $aParams, $hStatus
      , $aExpectedActions) = @_;

  $aExpectedActions = $ADD_ACTIONS unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;


  $aParams =[] unless defined($aParams);
  my ($iDepth, $bForceAdd, $bNoIgnore, $bAddParents) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams);

  my @aAdd = $bMinimal
    ? ( sub { $oClient->add($_[0]) }
      , sub { $oClient->add1_1($_[0]) }
      , sub { $oClient->add1_4($_[0]) }
      , sub { $oClient->add1_5($_[0]) }
      , sub { $oClient->add1_6($_[0]) }
      , sub { $oClient->add1_7($_[0]) }
      )
    : ( sub { $oClient->add($_[0], $bRecurse) }
      , sub { $oClient->add1_1($_[0], $bRecurse) }
      , sub { $oClient->add1_4($_[0], $bRecurse, $bForceAdd
                               , $bNoIgnore) }
      , sub { $oClient->add1_5($_[0], $iDepth, $bForceAdd
                               , $bNoIgnore, $bAddParents) }
      , sub { $oClient->add1_6($_[0], $iDepth, $bForceAdd
                               , $bNoIgnore, $bAddParents) }
      , sub { $oClient->add1_7($_[0], $iDepth, $bForceAdd
                               , $bNoIgnore, $bAddParents) }
      );

  if (defined($aCreate)) {
    my $aWcs = $aPaths;
    my ($sRelPath, $sContent) = @$aCreate;
    $aPaths = [ map { $_->addFile($sRelPath, $sContent); } @$aWcs ];
  }

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:add$VERSION_SUFFIXES[$i]($sPath)";
    okNotifyActions { $aAdd[$i]->($sPath);
                     } $sTest, $aExpectedActions, 1;
    okGetStatus($sName, $oClient, $sPath, $hStatus);

  }
  return $aPaths;
}

#----------------------------------------------------------------

sub okBlame {
  my ($sName, $oClient, $xPaths, $aParams, $iEdits, $sContent) = @_;
  my $aExpectedActions
    = [ ($SVN::Wc::Notify::Action::blame_revision) x $iEdits ];

  #blame only accepts central repository files
  #if one tries to use a local path one gets an 'Entry has no URL'
  #message

  my ($aPaths, $xPeg, $aRanges) = ref($xPaths) ? @$xPaths : ($xPaths);
  my ($xStart, $xEnd) = defined($aRanges) && (scalar @$aRanges)
    ? @{$aRanges->[0]} : (undef, undef);

  $aParams = [] unless defined $aParams;
  my ($oDiffOptions, $bBlameBinary, $bIncludeMergedRevisions)
    = @$aParams;
  my $bMinimal = _isMinimal($aParams, $xPeg, $aRanges);

  my @aBlame = $bMinimal
    ? ( sub { $oClient->blame($_[0], $_[1]) }
      , sub { $oClient->blame1_1($_[0], $_[1]) }
      , sub { $oClient->blame1_4($_[0], $xPeg, $xStart, $xEnd
            , $oDiffOptions, $bBlameBinary, $_[1]) }
      , sub { $oClient->blame1_5($_[0], $xPeg, $xStart, $xEnd
            , $oDiffOptions, $bBlameBinary, $bIncludeMergedRevisions
            , $_[1]) }
      , sub { $oClient->blame1_6($_[0], $xPeg, $xStart, $xEnd
            , $oDiffOptions, $bBlameBinary, $bIncludeMergedRevisions
            , $_[1]) }
      , sub { $oClient->blame1_7($_[0], $xPeg, $xStart, $xEnd
            , $oDiffOptions, $bBlameBinary, $bIncludeMergedRevisions
            , $_[1]) }
      )
    : ( sub { $oClient->blame($_[0],$xStart, $xEnd, $_[1]) }
      , sub { $oClient->blame1_1($_[0], $xStart, $xEnd, $_[1]) }
      , sub { $oClient->blame1_4($_[0], $xPeg, $xStart, $xEnd
            , $oDiffOptions, $bBlameBinary, $_[1]) }
      , sub { $oClient->blame1_5($_[0], $xPeg, $xStart, $xEnd
            , $oDiffOptions, $bBlameBinary, $bIncludeMergedRevisions
            , $_[1]) }
      , sub { $oClient->blame1_6($_[0], $xPeg, $xStart, $xEnd
            , $oDiffOptions, $bBlameBinary, $bIncludeMergedRevisions
            , $_[1]) }
      , sub { $oClient->blame1_7($_[0], $xPeg, $xStart, $xEnd
            , $oDiffOptions, $bBlameBinary, $bIncludeMergedRevisions
            , $_[1]) }
      );

  my $bOk=1;
  my $sMsg='';
  my $sBuf='';
  my $crVisit = sub {
    my ($iLine, $iRevision, $sAuthor, $sISO8601Time, $sLine, $oPool)
      = @_;

    $sBuf .= "$sLine\n" if defined($sLine);
    return unless $bOk;  #only capture first set of errors

    if ("$iLine" !~ m{\d+}) {
      $bOk=0;
      $sMsg.= "line: expected \\d+, got <$iLine>\n";
    }
    if ("$iRevision" !~ m{\d+}) {
      $bOk=0;
      $sMsg.= "revision: expected \\d+, got <$iRevision>\n";
    }
    if (!defined($sAuthor) || ref($sAuthor) || !length($sAuthor)) {
      $bOk=0;
      $sAuthor=defined($sAuthor)?"'$sAuthor'" : 'undef';
      $sMsg .= "author: expected non-empty string, got <$sAuthor>\n";
    }
    if (!defined($sISO8601Time) || ref($sISO8601Time)
      || !length($sISO8601Time)) {
      $bOk=0;
      $sISO8601Time= defined($sISO8601Time)
        ? "'$sISO8601Time'" : 'undef';
      $sMsg .= "timestamp: expected non-empty string, got "
        ."<$sISO8601Time>\n";
    }
    if (!defined($sLine) || ref($sLine) || !length($sLine)) {
      $bOk=0;
      $sLine=defined($sLine) ? "'$sLine'" : 'undef';
      $sMsg .= "line: expected non-empty string, got <$sLine>\n";
    }
    if (!defined($oPool) || ref($oPool) ne '_p_apr_pool_t') {
      $oPool=defined($oPool) ? "'$oPool'" : 'undef';
      $sMsg .= 'pool object: expected reference to svn_pool_t'
        . "got <$oPool>\n";
    }
  };

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:blame$VERSION_SUFFIXES[$i]($sPath)";

    okNotifyActions { $aBlame[$i]->($sPath, undef);
                     } $sTest, $aExpectedActions;
    $bOk=1;
    $sMsg='';
    $sBuf='';
    okNotifyActions { $aBlame[$i]->($sPath, $crVisit);
                     } $sTest, $aExpectedActions;

    ok($bOk, "$sTest - verifying callback parameters")
      or diag($sMsg);
    is($sBuf, $sContent, "$sTest - verifying content");
  }
}

#----------------------------------------------------------------

sub okCat {
  my ($sName, $oClient, $xPaths, $aParams, $sContent) = @_;
  my $aExpectedActions = [];

  my ($aPaths, $xPeg, $xRev) = ref($xPaths) ? @$xPaths : ($xPaths);

  $aParams = [] unless defined $aParams;
  my $bMinimal = _isMinimal($aParams, $xPeg, $xRev);

  my @aCat = $bMinimal
    ? ( sub { $oClient->cat($_[0],$xPeg, $_[1]) }
      , sub { $oClient->cat1_1($_[1], $_[0]) }
      , sub { $oClient->cat1_4($_[1], $_[0]) }
      , sub { $oClient->cat1_5($_[1], $_[0]) }
      , sub { $oClient->cat1_6($_[1], $_[0]) }
      , sub { $oClient->cat1_7($_[1], $_[0]) }
      )
    : ( sub { $oClient->cat($_[0],$xPeg, $_[1]) }
      , sub { $oClient->cat1_1($_[1], $_[0], $xPeg) }
      , sub { $oClient->cat1_4($_[1], $_[0]) }
      , sub { $oClient->cat1_5($_[1], $_[0]) }
      , sub { $oClient->cat1_6($_[1], $_[0]) }
      , sub { $oClient->cat1_7($_[1], $_[0]) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:cat$VERSION_SUFFIXES[$i]($sPath)";

    my $sBufOut='';
    open( my $fhOut, '>', \$sBufOut)
      or die "Cannot open string buffer stream: $!";
    okNotifyActions { $aCat[$i]->($sPath, $fhOut);
                     } $sTest, $aExpectedActions;

    is($sBufOut, $sContent, "$sTest - verifying content");
    close($fhOut);
  }
}

#----------------------------------------------------------------

sub okCheckout {
  my ($sName, $oClient, $xRepoURLs, $aPaths, $aParams
      , $aRepos, $bWc, $iExpectedRev, $aExpectedActions) = @_;

  my ($aRepoURLs, $xPeg, $xRev)
    = ref($xRepoURLs) ? @$xRepoURLs : ($xRepoURLs);
  $aRepoURLs = [ $aRepoURLs ] if ! ref($aRepoURLs);
  my $bCommitted= defined($xPeg) && ($xPeg ne 'WORKING');

  if (!defined($aExpectedActions)) {
    $aExpectedActions
      = [ $SVN::Wc::Notify::Action::update_update
          , $SVN::Wc::Notify::Action::update_completed ];
  }

  $aParams = [] unless defined($aParams);
  my ($iDepth, $bSkipExternals
      , $bAllowUnversionedObstructions) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams, $xPeg, $xRev);

  my @aCheckout = $bMinimal
    ?( sub { $oClient->checkout($_[0], undef, $_[1]) }
      , sub { $oClient->checkout1_1($_[0], $_[1])  }
      , sub { $oClient->checkout1_4($_[0], $_[1])  }
      , sub { $oClient->checkout1_5($_[0], $_[1])  }
      , sub { $oClient->checkout1_6($_[0], $_[1])  }
      , sub { $oClient->checkout1_7($_[0], $_[1])  }
      )
    :( sub { $oClient->checkout($_[0], $xPeg, $_[1], $bRecurse) }
      , sub { $oClient->checkout1_1($_[0], $_[1], $xPeg
                , $bRecurse);  }
      , sub { $oClient->checkout1_4($_[0], $_[1], $xPeg, $xRev
                , $bRecurse, $bSkipExternals);  }
      , sub { $oClient->checkout1_5($_[0], $_[1], $xPeg, $xRev
                , $iDepth, $bSkipExternals
                , $bAllowUnversionedObstructions);  }
      , sub { $oClient->checkout1_6($_[0], $_[1], $xPeg, $xRev
                , $iDepth, $bSkipExternals
                , $bAllowUnversionedObstructions);  }
      , sub { $oClient->checkout1_7($_[0], $_[1], $xPeg, $xRev
                , $iDepth, $bSkipExternals
                , $bAllowUnversionedObstructions);  }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next if !defined($sPath);

    my $oRepo = $aRepos->[$i];
    my $sRepoURL = $aRepoURLs->[$i];
    my $sTest
      ="$sName: checkout$VERSION_SUFFIXES[$i]($sPath => $sRepoURL)";

    is($oClient->isWorkingCopyPath($sPath), $bWc?1:0
       , "$sTest: before checkout");

    my $iRev;
    okNotifyActions { $iRev = $aCheckout[$i]->($sRepoURL, $sPath)
                    } $sTest, $aExpectedActions, 1;
    is($iRev, $iExpectedRev, "$sTest - verifying revision");

    is($oClient->getRepositoryURL($sPath), $sRepoURL
       , "$sTest - verifying repository URL");

    is($oClient->getRepositoryUUID($sPath), $oRepo->getUUID()
       , "$sTest - verifying repository UUID");

    is($oClient->isWorkingCopyPath($sPath), 1
       , "$sTest: after checkout");
  }
}

#--------------------------------------------------------------------

sub okCleanup {
  my ($sName, $oClient, $aPaths, $aExpectedActions) = @_;

  $aExpectedActions = [] unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  my @aCleanup
    = ( sub { $oClient->cleanup($_[0]) }
      , sub { $oClient->cleanup1_1($_[0]) }
      , sub { $oClient->cleanup1_4($_[0]) }
      , sub { $oClient->cleanup1_5($_[0]) }
      , sub { $oClient->cleanup1_6($_[0]) }
      , sub { $oClient->cleanup1_7($_[0]) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:cleanup$VERSION_SUFFIXES[$i]($sPath)";
    okNotifyActions { $aCleanup[$i]->($sPath);
                     } $sTest, $aExpectedActions, 1;
    next unless $bVerify;

    is($oClient->getStatus($sPath)->locked(), 0
      , "$sTest - verifying frozen(locked) status");
  }
}

#--------------------------------------------------------------------

sub okCommit {
  my ($sName, $oClient, $aPaths, $aParams
      , $aExpectedStatus, $iRev, $aExpectedActions) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  $aExpectedStatus = [ ($aExpectedStatus) x scalar(@$aPaths) ]
    if (ref($aExpectedStatus) eq 'HASH');

  $aExpectedActions = [] unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;


  $aParams=[] unless defined($aParams);
  my ($sComment, $iDepth, $bKeepLocks, $bKeepChangelists
      , $aChangeLists, $hRevProps, $crCommit) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bNonRecursive = !defined($bRecurse)? undef : ($bRecurse?0:1);
  my $bMinimal = _isMinimal($aParams);

  #print STDERR "recursive=", (defined($bRecurse)?$bRecurse:'undef')
  #  , "\n";

  my @aCommit = $bMinimal
    ? ( sub { $oClient->commit($_[0]) }
      , sub { $oClient->commit1_1($_[0]) }
      , sub { $oClient->commit1_4($_[0]) }
      , sub { $oClient->commit1_5($_[0]) }
      , sub { $oClient->commit1_6($_[0]) }
      , sub { $oClient->commit1_7($_[0]) }
      )
    : ( sub { $oClient->commit($_[0], $sComment, $bRecurse) }
      , sub { $oClient->commit1_1($_[0], $sComment, $bNonRecursive) }
      , sub { $oClient->commit1_4($_[0], $sComment, $bRecurse
            , $bKeepLocks) }
      , sub { $oClient->commit1_5($_[0], $sComment, $iDepth
            , $bKeepLocks, $bKeepChangelists, $aChangeLists
            , $hRevProps) }
      , sub { $oClient->commit1_6($_[0], $sComment, $iDepth
            , $bKeepLocks, $bKeepChangelists, $aChangeLists
            , $hRevProps) }
      , sub { $oClient->commit1_7($_[0], $sComment, $iDepth
            , $bKeepLocks, $bKeepChangelists, $aChangeLists
            , $hRevProps, $crCommit) }
      );


  for my $i (0..$#$aPaths) {
    my $xPath = $aPaths->[$i];
    next unless defined($xPath);

    my $aCommit = ref($xPath) eq 'ARRAY' ? $xPath : [ $xPath ];
    my $sTest = "$sName:commit$VERSION_SUFFIXES[$i](@$aCommit)";

    my $oCommitInfo;
    okNotifyActions { $oCommitInfo = $aCommit[$i]->($xPath);
                     } $sTest, $aExpectedActions, 1;
    next unless $bVerify;

    #if (!ref($xPath)) {
    #  local $"="\n\t";
    #  print STDERR "$sTest:\n\t@{$SANDBOX->list($xPath,1)}";
    #}

    SKIP:
    {
      if ($SKIP_SWIG_BUGS && ($i >= $IDX_SVN1_4)) {
        my $sBug= "commit: svn_commit_info_t package "
          ."undefined in SWIG-Perl (1.4), revision method unknown (1.5)";
        $SWIG_BINDING_BUGS{$sBug}++;
        local $TODO = "SWIG binding bug: need to report\n\t$sBug";
        skip $sTest, 1;
      }

      # eval because if we don't skip this bug it will cause
      # a fatal error and we'd rather see the error message and
      # continue

      eval {
        is(defined($oCommitInfo) ? $oCommitInfo->revision : undef
           , $iRev, "$sTest - verifying revision number");
      } or do {
        my $e=$@;
        $e='unknown' if defined($e) && !length($e);
        warn "$sTest: $e";
      };
    }

    for my $i (0..$#$aCommit) {
      my $sCommit = $aCommit->[$i];
      my $hExpect = $aExpectedStatus->[$i];
      okGetStatus($sTest, $oClient, $sCommit, $hExpect);
    }
  }
}

#--------------------------------------------------------------------

sub okCopy {
  my ($sName, $oClient, $xFrom, $aTo, $sRelPath, $aParams
  , $aExpectedActions) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  # $xFrom may be: $sPath
  #                [ $sPath, $xPeg, $xRev]
  #                [ $aPaths, $xPeg, $xRev]

  my ($aFrom, $xPeg, $xRev) = ref($xFrom) ? @$xFrom : ($xFrom);
  $aFrom = [ $aFrom ] if ! ref($aFrom);
  my $bLocal = !defined($xPeg) || (uc($xPeg) eq 'WORKING');


  $aExpectedActions = ($bLocal ? $COPY_ACTIONS : [])
    unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;


  if (defined($sRelPath)) {
    my $aWcs = $aTo;
    my ($sRelPath, $bFile) = ref($sRelPath)
      ? @$sRelPath : ($sRelPath);
    $aTo = [ map { $_->getFullPathName($sRelPath, $bFile) } @$aWcs ];
  }

  $aParams=[] unless defined($aParams);
  my ($sComment, $bCopyAsChild, $bMakeParents
     , $hRevProps, $crCommit) = @$aParams;
  my $bMinimal = _isMinimal($aParams, $xPeg);

  my @aCopy = $bMinimal
    ? ( sub { $oClient->copy($_[0], $xPeg, $_[1]); }
        , sub { $oClient->copy1_1($_[0], $xPeg, $_[1]) }
        , sub { $oClient->copy1_4($_[0], $xPeg, $_[1]) }
        , sub { $oClient->copy1_5($_[0], $xPeg, $_[1]) }
        , sub { $oClient->copy1_6($_[0], $xPeg, $_[1]) }
        , sub { $oClient->copy1_7($_[0], $xPeg, $_[1]) }
      )
    : ( sub { $oClient->copy($_[0], $xPeg, $_[1], $sComment); }
        , sub { $oClient->copy1_1($_[0], $xPeg, $_[1], $sComment) }
        , sub { $oClient->copy1_4($_[0], $xPeg, $_[1], $sComment) }
        , sub { $oClient->copy1_5($_[0], $xPeg, $_[1], $sComment
              , $bCopyAsChild, $bMakeParents, $hRevProps) }
        , sub { $oClient->copy1_6($_[0], $xPeg, $_[1], $sComment
              , $bCopyAsChild, $bMakeParents, $hRevProps) }
        , sub { $oClient->copy1_7($_[0], $xPeg, $_[1], $sComment
              , $bCopyAsChild, $bMakeParents, $hRevProps
              , $crCommit) }
     );

  for my $i (0..$#$aFrom) {
    my $sFrom = $aFrom->[$i];
    next unless defined($sFrom);

    my $sTo = $aTo->[$i];
    my $sTest = "$sName:copy$VERSION_SUFFIXES[$i]($sFrom => $sTo)";

    my $hFromStatus = $oClient->getStatus($sFrom);

    okNotifyActions { $aCopy[$i]->($sFrom, $sTo);
                     } $sTest, $aExpectedActions, 1;

    okGetStatus("$sTest - verifying preservation of source status"
                , $oClient, $sFrom, $hFromStatus);

    next unless $bVerify;

    if ($bLocal) {
      is((-e $sFrom)?1:0, 1
         , "$sTest - verifiying existance of source");
      okGetStatus("$sTest - verifying target status"
                  , $oClient, $sTo, $COPY_STATUS);
      is((-e $sTo)?1:0, 1, "$sTest - verifiying existance of target");
    }
  }
  return $aTo;
}

#--------------------------------------------------------------------

sub okDelete {
  my ($sName, $oClient, $aPaths, $aParams
      , $hExpectedStatus, $aExpectedActions) = @_;
  my $bLocal = defined($hExpectedStatus) ? 1 : 0;

  $aExpectedActions = ($bLocal ? $DEL_ACTIONS : [])
    unless defined($aExpectedActions);

  $aParams = [] unless defined($aParams);
  my ($sComment, $bForce, $bKeepLocal, $hRevProps, $crCommit)
    = @$aParams;
  my $bMinimal = _isMinimal($aParams);

  my @aDelete = $bMinimal
    ? ( sub { $oClient->delete($_[0]) }
      , sub { $oClient->delete1_1($_[0]) }
      , sub { $oClient->delete1_4($_[0]) }
      , sub { $oClient->delete1_5($_[0]) }
      , sub { $oClient->delete1_6($_[0]) }
      , sub { $oClient->delete1_7($_[0]) }
      )
    : ( sub { $oClient->delete($_[0], $sComment, $bForce) }
      , sub { $oClient->delete1_1($_[0], $sComment, $bForce) }
      , sub { $oClient->delete1_4($_[0], $sComment, $bForce) }
      , sub { $oClient->delete1_5($_[0], $sComment, $bForce
            , $bKeepLocal, $hRevProps) }
      , sub { $oClient->delete1_6($_[0], $sComment, $bForce
            , $bKeepLocal, $hRevProps) }
      , sub { $oClient->delete1_7($_[0], $sComment, $bForce
            , $bKeepLocal, $hRevProps, $crCommit) }
      );

  for my $i (0..$#$aPaths) {
    my $xPath = $aPaths->[$i];
    next unless defined($xPath);

    my $aPaths = ref($xPath) eq 'ARRAY' ? $xPath : [ $xPath ];

    my $sTest;
    {
      local $"=',';
      $sTest = "$sName:delete$VERSION_SUFFIXES[$i](@$aPaths)";
    }

    #dirs don't get removed until until commit
    my @aKeepUntilCommit= $bLocal
      ? map { (-d $_ ) ? 1 : 0 } @$aPaths
      : ();

    okNotifyActions { $aDelete[$i]->($xPath);
                     } $sTest, $aExpectedActions, 1;

    if ($bLocal) {
      foreach my $i (0..$#$aPaths) {
        my $sPath = $aPaths->[$i];
        okGetStatus($sName, $oClient, $sPath, $hExpectedStatus);
        is((-e $sPath) ? 1:0, $bKeepLocal ? 1 : $aKeepUntilCommit[$i]
           , "$sTest - verifying existance status");
      }
    }
  }
  return $aPaths;
}

#----------------------------------------------------------------

sub okDiff {
  my ($sName, $oClient, $xPath1, $xPath2, $aParams
      , $sOut, $sErr, $aExpectedActions)= @_;
  $aExpectedActions = [] unless defined($aExpectedActions);

  my ($aPath1, $xPeg1) = ref($xPath1) ? @$xPath1 : ($xPath1);
  my ($aPath2, $xPeg2) = ref($xPath2) ? @$xPath2 : ($xPath2);

  my ($iDepth, $aCmdLineOptions, $bIgnoreAncestry, $bIgnoreDeleted
      , $bShowCopiesAsAdds, $bDiffBinary, $bUseGitDiffFormat
      , $sHeaderEncoding, $aChangeLists) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $sRelativeToDir = undef;

  my $reOut = defined($sOut) && length($sOut)
    ? qr{\Q$sOut\E} : qr{^\z};
  my $reErr = defined($sErr) && length($sErr)
    ? qr{\Q$sErr\E} : qr{^\z};
  my $bMinimal = _isMinimal($aParams, $xPeg1, $xPeg2, $sOut, $sErr);

  my @aDiff = $bMinimal
    ? ( sub { $oClient->diff($_[0], $xPeg1, $_[1])}
        , sub {$oClient->diff1_1($aCmdLineOptions
              , $_[0], $xPeg1, $_[1])}
        , sub {$oClient->diff1_4($aCmdLineOptions
              , $_[0], $xPeg1, $_[1])}
        , sub {$oClient->diff1_6($aCmdLineOptions
              , $_[0], $xPeg1, $_[1])}
        , sub {$oClient->diff1_7($aCmdLineOptions
              , $_[0], $xPeg1, $_[1])}
      )
    : ( sub { $oClient->diff($_[0], $xPeg1, $_[1], $xPeg2, $bRecurse
              , $aCmdLineOptions, $bIgnoreAncestry, $bIgnoreDeleted
              , $_[2], $_[3])}
        , sub {$oClient->diff1_1($aCmdLineOptions
              , $_[0], $xPeg1, $_[1], $xPeg2, $bRecurse
              , $bIgnoreAncestry, $bIgnoreDeleted, $_[2], $_[3])}
        , sub {$oClient->diff1_4($aCmdLineOptions
              , $_[0], $xPeg1, $_[1], $xPeg2, $bRecurse
              , $bIgnoreAncestry, $bIgnoreDeleted, $bDiffBinary
              , $sHeaderEncoding, $_[2], $_[3])}
        , sub {$oClient->diff1_5($aCmdLineOptions
              , $_[0], $xPeg1, $_[1], $xPeg2, $sRelativeToDir
              , $iDepth, $bIgnoreAncestry, $bIgnoreDeleted
              , $bDiffBinary, $sHeaderEncoding, $_[2], $_[3]
              , $aChangeLists)}
        , sub {$oClient->diff1_6($aCmdLineOptions
              , $_[0], $xPeg1, $_[1], $xPeg2, $sRelativeToDir
              , $iDepth, $bIgnoreAncestry, $bIgnoreDeleted
              , $bDiffBinary, $sHeaderEncoding, $_[2], $_[3]
              , $aChangeLists)}
        , sub {$oClient->diff1_7($aCmdLineOptions
              , $_[0], $xPeg1, $_[1], $xPeg2, $sRelativeToDir
              , $iDepth, $bIgnoreAncestry, $bIgnoreDeleted
              , $bShowCopiesAsAdds, $bDiffBinary, $bUseGitDiffFormat
              , $sHeaderEncoding, $_[2], $_[3], $aChangeLists)}
      );

  for my $i (0..$#$aPath1) {
    my $sPath1 = $aPath1->[$i];
    next unless defined($sPath1);
    my $sPath2 = defined($aPath2) ? $aPath2->[$i] : undef;
    my $sTest  = "$sName: diff$VERSION_SUFFIXES[$i]($sPath1, "
      . (defined($sPath2)?$sPath2:'undef').")";

    my $fhOut = defined($sOut)
      ? $SANDBOX->createReadWriteStream() : undef;
    my $fhErr = defined($sErr)
      ? $SANDBOX->createReadWriteStream() : undef;

    if (okNotifyActions {
      $aDiff[$i]->($sPath1, $sPath2, $fhOut, $fhErr)
      } $sTest, $aExpectedActions) {

      local $/;
      if (defined($fhOut)) {
        seek($fhOut, 0, 0);
        like(<$fhOut>, $reOut, "$sTest - verifying output stream");
      }

      if (defined($fhErr)) {
        seek($fhErr, 0, 0);
        like(<$fhErr>, $reErr, "$sTest - verifying error stream");
      }
    }
    close $fhOut if defined($fhOut);
    close $fhErr if defined($fhErr);
  }
}

#--------------------------------------------------------------------

sub okExport {
  my ($sName, $oClient, $xPaths, $aExport, $aParams
      , $aListing, $aExpectedActions) = @_;

  $aListing = [ sort @$aListing ];

  my ($aPaths, $xPeg, $xRev) = ref($xPaths) ? @$xPaths : ($xPaths);
  $aPaths = [ $aPaths ] if ! ref($aPaths);
  my $bCommitted= defined($xPeg) && ($xPeg ne 'WORKING');


  # if exporting from the repository, one add for each file +
  #   one for the containing directory
  # whether from the repository or working copy,
  #   there is a update_completed action

  if (!defined($aExpectedActions)) {
    $aExpectedActions = $bCommitted
      ? [($SVN::Wc::Notify::Action::update_add)
         x (scalar(@$aListing)+1)]
      : [];
    push @$aExpectedActions
      , $SVN::Wc::Notify::Action::update_completed;
  }

  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  $aParams=[] unless defined($aParams);
  my ($iDepth, $bOverwrite, $bSkipExternals, $bIgnoreKeywords
     , $sNativeEol, $oPool) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams, $xPeg, $xRev);

  my @aExport = $bMinimal
    ? ( sub { $oClient->export($_[0],$xPeg,  $_[1]) }
      , sub { $oClient->export1_1($_[0], $_[1]) }
      , sub { $oClient->export1_4($_[0], $_[1]) }
      , sub { $oClient->export1_5($_[0], $_[1]) }
      , sub { $oClient->export1_6($_[0], $_[1]) }
      , sub { $oClient->export1_7($_[0], $_[1]) }
      )
    : ( sub { $oClient->export($_[0], $xPeg, $_[1], $bOverwrite
            , $oPool) }
      , sub { $oClient->export1_1($_[0], $_[1], $xPeg, $bOverwrite
            , $sNativeEol, $oPool) }
      , sub { $oClient->export1_4($_[0], $_[1], $xPeg, $xRev
            , $bOverwrite, $bSkipExternals, $bRecurse, $sNativeEol
            , $oPool) }
      , sub { $oClient->export1_5($_[0], $_[1], $xPeg, $xRev
            , $bOverwrite, $bSkipExternals, $iDepth, $sNativeEol
            , $oPool) }
      , sub { $oClient->export1_6($_[0], $_[1], $xPeg, $xRev
            , $bOverwrite, $bSkipExternals, $iDepth, $sNativeEol
            , $oPool) }
      , sub { $oClient->export1_7($_[0], $_[1], $xPeg, $xRev
            , $bOverwrite, $bSkipExternals, $bIgnoreKeywords
            , $iDepth, $sNativeEol, $oPool) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);

    my $sExport = $aExport->[$i];
    my $sTest
      = "$sName: export$VERSION_SUFFIXES[$i]($sPath=>$sExport)";
    okNotifyActions { $aExport[$i]->($sPath, $sExport);
                     } $sTest, $aExpectedActions;
    next unless $bVerify;

    ok(-d $sExport, "$sTest: exported directory exists");

    my $aGot = [ sort @{$SANDBOX->list($sExport,1)} ];
    is_deeply($aGot, $aListing
              , "$sTest: verifying directory contents")
      or diag("got=(@$aGot)\nexpected=(@$aListing)\n");
  }
  return $aPaths;
}

#--------------------------------------------------------------------

sub okGetStatus {
  my ($sTest, $oClient, $sPath, $hExpectedStatus) = @_;

  if (defined($hExpectedStatus)
      && (ref($hExpectedStatus) ne 'HASH')) {
    $hExpectedStatus
      = { text_status => $hExpectedStatus->text_status()
        , prop_status => $hExpectedStatus->prop_status()
        , locked => $hExpectedStatus->locked()
        , copied => $hExpectedStatus->copied()
        , switched => $hExpectedStatus->switched()
        , repos_text_status => $hExpectedStatus->repos_text_status()
        , repos_prop_status => $hExpectedStatus->repos_prop_status()
        };
  }

  my $oStatus = $oClient->getStatus($sPath);
  my $hGot = ref($oStatus)
    ? { text_status => $oStatus->text_status()
        , prop_status => $oStatus->prop_status()
        , locked => $oStatus->locked()
        , copied => $oStatus->copied()
        , switched => $oStatus->switched()
        , repos_text_status => $oStatus->repos_text_status()
        , repos_prop_status => $oStatus->repos_prop_status()
      } : $oStatus;
  return is_deeply($hGot, $hExpectedStatus
                   , "$sTest: verifying status");
}

#--------------------------------------------------------------------

sub okImport {
  my ($sName, $oClient, $sImport, $aRepoURLs, $sBranch, $aParams
      , $iRev, $aListing, $aExpectedActions) = @_;

  $aListing = [ sort @$aListing ];
  $aExpectedActions
    =[ ($SVN::Wc::Notify::Action::commit_added) x scalar(@$aListing) ]
    unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;


  $aParams=[] unless defined($aParams);
  my ($sComment, $iDepth, $bNoIgnore, $bIgnoreUnknownNodeTypes
     , $hRevProp, $crCommit, $oPool) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bNonRecursive = !defined($bRecurse)? undef : ($bRecurse?0:1);
  my $bMinimal = _isMinimal($aParams);

  my @aImport = $bMinimal
    ? ( sub { $oClient->import($_[0], $_[1]) }
      , sub { $oClient->import1_1($_[0], $_[1]) }
      , sub { $oClient->import1_4($_[0], $_[1]) }
      , sub { $oClient->import1_5($_[0], $_[1]) }
      , sub { $oClient->import1_6($_[0], $_[1]) }
      , sub { $oClient->import1_7($_[0], $_[1]) }
      )
    : ( sub { $oClient->import($_[0], $_[1], $sComment
            , $bRecurse, $oPool) }
      , sub { $oClient->import1_1($_[0], $_[1], $sComment
            , $bNonRecursive, $oPool) }
      , sub { $oClient->import1_4($_[0], $_[1], $sComment
            , $bNonRecursive, $bNoIgnore, $oPool) }
      , sub { $oClient->import1_5($_[0], $_[1], $sComment, $iDepth
            , $bNoIgnore, $bIgnoreUnknownNodeTypes, $hRevProp
            , $oPool) }
      , sub { $oClient->import1_6($_[0], $_[1], $sComment, $iDepth
            , $bNoIgnore, $bIgnoreUnknownNodeTypes, $hRevProp
            , $oPool) }
      , sub { $oClient->import1_7($_[0], $_[1], $sComment, $iDepth
            , $bNoIgnore, $bIgnoreUnknownNodeTypes, $hRevProp
            , $crCommit, $oPool) }
      );

  my @aPaths;
  for my $i (0..$#$aRepoURLs) {
    my $sRepoURL = $aRepoURLs->[$i];
    next unless defined($sRepoURL);

    # POSIX paths can be appended to http URL's but not necessarily
    # file URLs.
    my $sPath =  $sRepoURL =~ m{^file://(.*)$}
      ? 'file://' . File::Spec->rel2abs($sBranch, $1)
      : "$sRepoURL/$sBranch";
    push @aPaths, $sPath;

    my $sTest
      = "$sName: import$VERSION_SUFFIXES[$i]($sImport=>$sPath)";

    my $oCommitInfo;
    okNotifyActions { $oCommitInfo = $aImport[$i]->($sImport,$sPath);
                     } $sTest, $aExpectedActions, 1;
    next unless $bVerify;

    SKIP: {
        if ($SKIP_SWIG_BUGS && ($i >= $IDX_SVN1_4)) {
          my $sBug="commit: svn_commit_info_t package "
            ."undefined in SWIG-Perl";
          $SWIG_BINDING_BUGS{$sBug}++;
          local $TODO = "SWIG binding bug: need to report\n\t$sBug";
          skip $sTest, 1;
        }

        # eval because if we don't skip this bug it will cause
        # a fatal error and we'd rather see the error message and
        # continue

        eval {
          is(defined($oCommitInfo) ? $oCommitInfo->revision : undef
             , $iRev, "$sTest - verifying revision number");
        } or do {
          my $e=$@;
          $e='unknown' if defined($e) && !length($e);
          warn "$sTest: $e";
        };
      }

    my $aGot = [ sort @{$oClient->getPathList($sPath, $iRev)} ];
    is_deeply($aGot, $aListing
              , "$sTest: verifying directory contents")
      or diag("got=(@$aGot)\nexpected=(@$aListing)\n");
  }
  return \@aPaths;
}

#--------------------------------------------------------------------

sub okInfo {
  my ($sName, $oClient, $xPaths, $aParams
      , $iVisits, $hExpectedInfo, $aExpectedActions) = @_;
  $aExpectedActions = [] unless defined($aExpectedActions);

  my ($aPaths, $xPeg, $xRev) = ref($xPaths) ? @$xPaths : ($xPaths);

  $aParams = [] unless defined($aParams);
  my ($iDepth, $aChangeLists) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams, $xPeg, $xRev);

  my @aInfo = $bMinimal
    ? ( sub { $oClient->info($_[0],$xPeg, $xRev, $_[1]) }
      , sub { $oClient->info1_1($_[0], $xPeg, $xRev, $_[1]) }
      , sub { $oClient->info1_4($_[0], $xPeg, $xRev, $_[1]) }
      , sub { $oClient->info1_5($_[0], $xPeg, $xRev, $_[1]) }
      , sub { $oClient->info1_6($_[0], $xPeg, $xRev, $_[1]) }
      , sub { $oClient->info1_7($_[0], $xPeg, $xRev, $_[1]) }
      )
    : ( sub { $oClient->info($_[0],$xPeg, $xRev, $_[1]) }
      , sub { $oClient->info1_1($_[0], $xPeg, $xRev, $_[1]) }
      , sub { $oClient->info1_4($_[0], $xPeg, $xRev, $_[1]
            , $bRecurse) }
      , sub { $oClient->info1_5($_[0], $xPeg, $xRev, $_[1]
            , $iDepth, $aChangeLists) }
      , sub { $oClient->info1_6($_[0], $xPeg, $xRev, $_[1]
            , $iDepth, $aChangeLists) }
      , sub { $oClient->info1_7($_[0], $xPeg, $xRev, $_[1]
            , $iDepth, $aChangeLists) }
      );

  my $bOk=1;
  my $sMsg='';
  my $hInfo={};
  my @aVisits;
  my $IDX_PATH = 0;
  my $IDX_REV=1;
  my $IDX_LOCK = 2;

  my $crVisit = sub {
    my ($sPath, $oInfo, $oPool) = @_;

    my $sRepoURL = $oInfo->URL();
    my $xPeg = $oInfo->rev();
    my $xLocked = $oInfo->lock();

    push @aVisits, [$sRepoURL, $xPeg, $xLocked];

    if ($NOISY) {
      print STDERR "info: url=<$sRepoURL> rev=<$xPeg"
        . "> kind=<" . $CLIENT_CLASS->getKindAsString($oInfo->kind())
        . "> repo_root=<" . $oInfo->repos_root_URL()
        . "> lock=<" . ($xLocked ? $xLocked : 'undef')
        . ">\n";
    }

    return unless $bOk;  # only capture errors once

    if (!defined($sPath) || ref($sPath) || !length($sPath)) {
      $bOk=0;
      $sPath=defined($sPath) ? "'$sPath'" : 'undef';
      $sMsg .= "path: expected non-empty string, got <$sPath>\n";
    }
    if (!defined($oInfo) || ref($oInfo) ne '_p_svn_info_t') {
      $oInfo=defined($oInfo) ? "'$oInfo'" : 'undef';
      $sMsg .= 'info object: expected reference to svn_info_t'
        . ", got <$oInfo>\n";
    }
    if (!defined($oPool) || ref($oPool) ne '_p_apr_pool_t') {
      $oPool=defined($oPool) ? "'$oPool'" : 'undef';
      $sMsg .= 'pool object: expected reference to svn_pool_t'
        . ", got <$oPool>\n";
    }

    if (scalar(@aVisits) == 1) {
      $hInfo->{last_changed_rev} = $oInfo->last_changed_rev;
      $hInfo->{kind} = $oInfo->kind();
      $hInfo->{lock} = $oInfo->lock()?1:0;
      $hInfo->{repos_UUID} = $oInfo->repos_UUID();
      $hInfo->{repos_URL}  = $oInfo->repos_root_URL();
    }

  };

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:info$VERSION_SUFFIXES[$i]($sPath)";

    okNotifyActions { $aInfo[$i]->($sPath, undef);
                     } $sTest, $aExpectedActions;

    @aVisits=();
    $bOk=1;
    $sMsg='';
    okNotifyActions { $aInfo[$i]->($sPath, $crVisit);
                     } $sTest, $aExpectedActions;

    $hExpectedInfo->{repos_UUID}
      = $oClient->getRepositoryUUID($sPath);
    $hExpectedInfo->{repos_URL}
      = $oClient->getRepositoryRootURL($sPath);
    is_deeply($hInfo, $hExpectedInfo
      , "$sTest - verifying retrieved data");
    is(scalar(@aVisits), $iVisits, "$sTest - verifying visit count");

    ok($bOk, "$sTest - verifying callback parameters")
      or diag($sMsg);
  }
}

#----------------------------------------------------------------

sub okList {
  my ($sName, $oClient, $xPath, $aParams
     , $aListing, $aExpectedActions) = @_;
  my $aExpectedPaths = defined($aListing) ? [ sort @$aListing ] : [];

  $aExpectedActions = [] unless defined($aExpectedActions);

  my ($aPaths, $xPeg, $xRev) = ref($xPath) ? @$xPath : ($xPath);

  $aParams = [] unless defined($aParams);
  my ($crVisit, $iDepth, $iFields, $bFetchLocks) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams, $xPeg, $xRev);

  my @aGot;
  my $crSavePaths = sub { push @aGot, $_[0] };

  my @aList = $bMinimal
    ? ( sub { $oClient->list($_[0], $xPeg, $_[1]) }
      , sub { $oClient->list1_1($_[0], $xPeg, $bRecurse,  $_[1]) }
      , sub { $oClient->list1_4($_[0], $xPeg, $xRev, $bRecurse
              , $iFields, $bFetchLocks, $_[1]) }
      , sub { $oClient->list1_5($_[0], $xPeg, $xRev, $iDepth
              , $bFetchLocks, $_[1]) }
      , sub { $oClient->list1_6($_[0], $xPeg, $xRev, $iDepth
              , $bFetchLocks, $_[1]) }
      , sub { $oClient->list1_7($_[0], $xPeg, $xRev, $iDepth
              , $bFetchLocks, $_[1]) }
      )
    : ( sub { $oClient->list($_[0], $xPeg, $_[1], $bRecurse) }
      , sub { $oClient->list1_1($_[0], $xPeg, $bRecurse,  $_[1]) }
      , sub { $oClient->list1_4($_[0], $xPeg, $xRev, $bRecurse
              , $iFields, $bFetchLocks, $_[1]) }
      , sub { $oClient->list1_5($_[0], $xPeg, $xRev, $iDepth
              , $bFetchLocks, $_[1]) }
      , sub { $oClient->list1_6($_[0], $xPeg, $xRev, $iDepth
              , $bFetchLocks, $_[1]) }
      , sub { $oClient->list1_7($_[0], $xPeg, $xRev, $iDepth
              , $bFetchLocks, $_[1]) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:list$VERSION_SUFFIXES[$i]($sPath)";

  SKIP: {
      if ($SKIP_SWIG_BUGS && ($i == $IDX_SVN1_4)) {
        my $sBug="list: svn_client_list thunk undefined in SWIG-Perl";
        $SWIG_BINDING_BUGS{$sBug}++;
        local $TODO = "SWIG binding bug: need to report\n\t$sBug";
        skip $sTest, 1;
      }

      okNotifyActions { $aList[$i]->($sPath, $crVisit);
                       } $sTest, $aExpectedActions;

      # eval this in case we don't skip the bug
      eval {
        @aGot=();
        $aList[$i]->($sPath, $crSavePaths);
        is_deeply([sort @aGot], $aExpectedPaths
                  , "$sTest - verifying path list")
          or diag("\ngot=(@{[sort @aGot]})"
                  ."\nexpected=(@$aExpectedPaths)\n");
        return 1;
      } or do {
        my $e=$@;
        $e='unknown reason' if defined($e) && !length($e);
        warn "$sTest: $e";
      }
    }
  }

  # these methods are only have a 1.1 version
  {
    my $sPath = $aPaths->[0];

    my $sTest = "$sName:ls($sPath)";
    my $hEntries = $oClient->ls1_1($sPath, $xPeg, $bRecurse);
    is_deeply([sort keys %$hEntries], $aExpectedPaths
       , "$sTest - verifying hash keys");
    is_deeply([ grep { ref($_) ne '_p_svn_dirent_t'
                     } values %$hEntries]
       ,[], "$sTest - verifying hash values");

    $sTest = "$sName:getPathList($sPath)";
    my $aPaths = $oClient->getPathList($sPath, $xPeg, $xRev);
    is_deeply([ sort @$aPaths], $aExpectedPaths, $sTest);
  }
}

#--------------------------------------------------------------------

sub okLock {
  my ($sName, $oClient, $aPaths, $aParams, $aExpectedActions) = @_;

  $aParams=[] unless defined($aParams);
  my ($sComment, $bStealLock) = @$aParams;
  my $bMinimal = _isMinimal($aParams);

  my @aLock = $bMinimal
    ? ( sub { $oClient->lock($_[0]) }
      , sub { $oClient->lock1_1($_[0]) }
      , sub { $oClient->lock1_4($_[0]) }
      , sub { $oClient->lock1_5($_[0]) }
      , sub { $oClient->lock1_6($_[0]) }
      , sub { $oClient->lock1_7($_[0]) }
      )
    : ( sub { $oClient->lock($_[0], $sComment, $bStealLock) }
      , sub { $oClient->lock1_1($_[0], $sComment, $bStealLock) }
      , sub { $oClient->lock1_4($_[0], $sComment, $bStealLock) }
      , sub { $oClient->lock1_5($_[0], $sComment, $bStealLock) }
      , sub { $oClient->lock1_6($_[0], $sComment, $bStealLock) }
      , sub { $oClient->lock1_7($_[0], $sComment, $bStealLock) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:lock$VERSION_SUFFIXES[$i]($sPath)";
    okNotifyActions { $aLock[$i]->($sPath);
                     } $sTest, $aExpectedActions,1;

    my $oLock = $oClient->getInfo($sPath)->lock();
    ok($oLock, "$sName - verifying lock status");
    is($oLock->comment(), $sComment, "$sName - verifying comment");
  }
}

#--------------------------------------------------------------------

sub okLog {
  my ($sName, $oClient, $xPaths, $aParams
      , $iVisits, $aExpectedLogMessages, $aExpectedActions) = @_;

  $aExpectedActions = []    unless defined($aExpectedActions);

  my ($aPaths, $xPeg, $aRevRanges)
     = ref($xPaths) ? @$xPaths : ($xPaths);

  $aParams = [] unless defined($aParams);
  my ($iDepth, $iVisitLimit, $bChangedPaths, $bStrictNodeHistory
     , $bIncludeMergedRevisions, $aRevProps) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my ($xStart, $xEnd) = defined($aRevRanges) && scalar($aRevRanges)
    ? @{$aRevRanges->[0]} : (undef, undef);
  my $bMinimal = _isMinimal($aParams);

  my @aLog = $bMinimal
    ?  ( sub { $oClient->log($_[0],$xStart, $xEnd, $_[1]) }

      , sub { $oClient->log1_1($_[0],$xStart, $xEnd
            , $bChangedPaths, $bStrictNodeHistory, $_[1]) }
      , sub { $oClient->log1_4($_[0], $xPeg, $xStart, $xEnd
            , $iVisitLimit, $bChangedPaths, $bStrictNodeHistory
            , $_[1]) }
      , sub { $oClient->log1_5($_[0], $xPeg, $xStart, $xEnd
            , $iVisitLimit, $bChangedPaths, $bStrictNodeHistory
            , $bIncludeMergedRevisions, $aRevProps, $_[1]) }
      , sub { $oClient->log1_6($_[0], $xPeg, $aRevRanges
            , $iVisitLimit, $bChangedPaths, $bStrictNodeHistory
            , $bIncludeMergedRevisions, $aRevProps, $_[1]) }
      , sub { $oClient->log1_7($_[0], $xPeg, $aRevRanges
            , $iVisitLimit, $bChangedPaths, $bStrictNodeHistory
            , $bIncludeMergedRevisions, $aRevProps, $_[1]) }
      )
    : ( sub { $oClient->log($_[0],$xStart, $xEnd, $_[1]
            , $bChangedPaths, $bStrictNodeHistory) }

      , sub { $oClient->log1_1($_[0],$xStart, $xEnd
            , $bChangedPaths, $bStrictNodeHistory, $_[1]) }
      , sub { $oClient->log1_4($_[0], $xPeg, $xStart, $xEnd
            , $iVisitLimit, $bChangedPaths, $bStrictNodeHistory
            , $_[1]) }
      , sub { $oClient->log1_5($_[0], $xPeg, $xStart, $xEnd
            , $iVisitLimit, $bChangedPaths, $bStrictNodeHistory
            , $bIncludeMergedRevisions, $aRevProps, $_[1]) }
      , sub { $oClient->log1_6($_[0], $xPeg, $aRevRanges
            , $iVisitLimit, $bChangedPaths, $bStrictNodeHistory
            , $bIncludeMergedRevisions, $aRevProps, $_[1]) }
      , sub { $oClient->log1_7($_[0], $xPeg, $aRevRanges
            , $iVisitLimit, $bChangedPaths, $bStrictNodeHistory
            , $bIncludeMergedRevisions, $aRevProps, $_[1]) }
      );

  my $bOk=1;
  my $sMsg='';
  my @aGotMessages;
  my $iGotVisits=0;
  my $crVisit1 = sub {
    my ($hChangedPaths, $iRev, $sAuthor, $sDate, $sMessage
        , $oPool) = @_;

    push @aGotMessages, $sMessage;
    $iGotVisits++;
    return unless $bOk;  # only capture errors once

    $sMsg="rev=$iRev\n";

    if ($bChangedPaths) {
      if (!defined($hChangedPaths)
          || (ref($hChangedPaths) ne 'HASH')) {
        $bOk=0;
        $hChangedPaths= defined($hChangedPaths)
          ? "'$hChangedPaths'" : 'undef';
        $sMsg .= 'changed paths hash: expected reference to svn_log_t'
          . "m got <$hChangedPaths>\n";
      }
    } elsif (defined($hChangedPaths)) {
      $bOk=0;
      $sMsg .= "changed paths hash: unexpectedly defined - log() "
        . "was not called with bChangedPaths=true";
    }

    if ($iRev !~ m{\d+}) {
      $bOk=0;
      $sMsg.= "revision: expected \\d+, got <$iRev>\n";
    }
    if (!defined($sDate) || ref($sDate)
      || !length($sDate)) {
      $bOk=0;
      $sDate= defined($sDate) ? "'$sDate'" : 'undef';
      $sMsg .= "timestamp: expected non-empty string, got "
        ."<$sDate>\n";
    }
    if (!defined($sAuthor) || ref($sAuthor) || !length($sAuthor)) {
      $bOk=0;
      $sAuthor=defined($sAuthor) ? "'$sAuthor'" : 'undef';
      $sMsg .= "author: expected non-empty string, got <$sAuthor>\n";
    }
    if (!defined($sMessage) || ref($sMessage)) {
      $bOk=0;
      $sMessage=defined($sMessage) ? "'$sMessage'" : 'undef';
      $sMsg .= "message: expected a string, got <$sMessage>\n";
    }
    if (!defined($oPool) || ref($oPool) ne '_p_apr_pool_t') {
      $oPool=defined($oPool) ? "'$oPool'" : 'undef';
      $sMsg .= 'pool object: expected reference to svn_pool_t'
        . ", got <$oPool>\n";
    }
  };

  my $crVisit2 = sub {
    my ($oLogEntry, $oPool) = @_;
    if (!defined($oLogEntry)
        || ref($oLogEntry) ne '_p_svn_log_entry_t') {
      $oLogEntry=defined($oLogEntry) ? "'$oLogEntry'" : 'undef';
      $sMsg .= 'pool object: expected reference to svn_pool_t'
        . ", got <$oLogEntry>\n";
    }
    if (!defined($oPool) || ref($oPool) ne '_p_apr_pool_t') {
      $oPool=defined($oPool) ? "'$oPool'" : 'undef';
      $sMsg .= 'pool object: expected reference to svn_pool_t'
        . "got <$oPool>\n";
    }
  };

  my @aVisitors = ($crVisit1, $crVisit1, $crVisit1
                   , $crVisit2, $crVisit2, $crVisit2);

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:log$VERSION_SUFFIXES[$i]($sPath)";

    okNotifyActions { $aLog[$i]->($sPath, undef);
                     } $sTest, $aExpectedActions;

    $iGotVisits=0;
    $bOk=1;
    $sMsg='';
    @aGotMessages=();
    okNotifyActions { $aLog[$i]->($sPath, $aVisitors[$i]);
                     } $sTest, $aExpectedActions;

    is($iGotVisits, $iVisits, "$sTest - verifying visit count");
    is_deeply(\@aGotMessages, $aExpectedLogMessages
      , "$sTest - verifying log messages");

    ok($bOk, "$sTest - verifying callback parameters")
      or diag($sMsg);
  }
}

#----------------------------------------------------------------

sub okMerge {
  my ($sName, $oClient, $xPath1, $xPath2, $aWcs, $aParams
      , $aList, $aExpectedActions)= @_;

  $aExpectedActions = $MERGE_ACTIONS
    unless defined($aExpectedActions);

  my ($aPath1, $xPeg1) = ref($xPath1) ? @$xPath1 : ($xPath1);
  my ($aPath2, $xPeg2) = ref($xPath2) ? @$xPath2 : ($xPath2);

  my ($iDepth, $aMergeOptions, $bIgnoreAncestry, $bForceDelete
      , $bDryRun, $bRecordOnly, $bAllowMixedRevs) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams, $xPeg1, $xPeg2);


  my @aMerge = $bMinimal
    ?  ( sub { $oClient->merge($_[0], $xPeg1, $_[1], $xPeg2, $_[2])}
        , sub {$oClient->merge1_1($_[0], $xPeg1, $_[1], $xPeg2,$_[2])}
        , sub {$oClient->merge1_4($_[0], $xPeg1, $_[1], $xPeg2,$_[2])}
        , sub {$oClient->merge1_5($_[0], $xPeg1, $_[1], $xPeg2,$_[2])}
        , sub {$oClient->merge1_6($_[0], $xPeg1, $_[1], $xPeg2,$_[2])}
        , sub {$oClient->merge1_7($_[0], $xPeg1, $_[1], $xPeg2,$_[2])}
      )
    : ( sub { $oClient->merge($_[0], $xPeg1, $_[1], $xPeg2, $_[2]
              , $bRecurse, $bIgnoreAncestry, $bForceDelete, $bDryRun
              )}
        , sub {$oClient->merge1_1($_[0], $xPeg1, $_[1], $xPeg2, $_[2]
              , $bRecurse, $bIgnoreAncestry, $bForceDelete, $bDryRun
              )}
        , sub {$oClient->merge1_4($_[0], $xPeg1, $_[1], $xPeg2, $_[2]
              , $bRecurse, $bIgnoreAncestry, $bForceDelete, $bDryRun
              , $aMergeOptions)}
        , sub {$oClient->merge1_5($_[0], $xPeg1, $_[1], $xPeg2, $_[2]
              , $iDepth, $bIgnoreAncestry, $bForceDelete, $bRecordOnly
              , $bDryRun, $aMergeOptions)}
        , sub {$oClient->merge1_6($_[0], $xPeg1, $_[1], $xPeg2, $_[2]
              , $iDepth, $bIgnoreAncestry, $bForceDelete, $bRecordOnly
              , $bDryRun, $aMergeOptions)}
        , sub {$oClient->merge1_7($_[0], $xPeg1, $_[1], $xPeg2, $_[2]
              , $iDepth, $bIgnoreAncestry, $bForceDelete, $bRecordOnly
              , $bDryRun, $bAllowMixedRevs, $aMergeOptions)}
      );

  for my $i (0..$#$aPath1) {
    my $sPath1 = $aPath1->[$i];
    next unless defined($sPath1);

    my $sPath2 = defined($aPath2) ? $aPath2->[$i] : undef;
    my $sWc    = $aWcs->[$i];
    my $sTest  = "$sName: merge$VERSION_SUFFIXES[$i]("
      ."$sPath1 - $sPath2 => $sWc)";

    okNotifyActions { $aMerge[$i]->($sPath1, $sPath2, $sWc)
                    } $sTest, $aExpectedActions, 1;
    # TODO:
    # get listing of files - from repo? from local dir?
    # compare to list.
  }
}

#--------------------------------------------------------------------

sub okMkdir {
  my ($sName, $oClient, $aPaths, $sRelPath, $aParams, $hExpectedStatus
      , $aExpectedActions) = @_;

  my $bLocal = defined($hExpectedStatus)?1:0;

  $aExpectedActions=($bLocal ? $ADD_ACTIONS : [])
    unless defined($aExpectedActions);

  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  $aParams=[] unless defined($aParams);
  my ($sComment, $bMakeParents, $hRevProps, $crCommit) = @$aParams;
  my $bMinimal = _isMinimal($aParams);

  if (defined($sRelPath)) {
    my $aWcs = $aPaths;
    $aPaths = [ map { $_->getFullPathName($sRelPath) } @$aWcs ];
  }

  my @aMkdir = $bMinimal
    ? ( sub { $oClient->mkdir($_[0]) }
      , sub { $oClient->mkdir1_1($_[0]) }
      , sub { $oClient->mkdir1_4($_[0]) }
      , sub { $oClient->mkdir1_5($_[0]) }
      , sub { $oClient->mkdir1_6($_[0]) }
      , sub { $oClient->mkdir1_7($_[0]) }
      )
    : ( sub { $oClient->mkdir($_[0], $sComment) }
      , sub { $oClient->mkdir1_1($_[0], $sComment) }
      , sub { $oClient->mkdir1_4($_[0], $sComment) }
      , sub { $oClient->mkdir1_5($_[0], $sComment, $bMakeParents
            , $hRevProps) }
      , sub { $oClient->mkdir1_6($_[0], $sComment, $bMakeParents
            , $hRevProps) }
      , sub { $oClient->mkdir1_7($_[0], $sComment, $bMakeParents
            , $hRevProps, $crCommit) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName: mkdir$VERSION_SUFFIXES[$i]($sPath)";
    okNotifyActions { $aMkdir[$i]->($sPath);
                     } $sTest, $aExpectedActions, 1;

    if ($bLocal) {
      okGetStatus($sTest, $oClient, $sPath, $hExpectedStatus);
    }

    next unless $bVerify;

    if ($bLocal) {
      ok(-d $sPath, "$sTest: created directory exists");
    }
  }
  return $aPaths;
}

#--------------------------------------------------------------------

sub okMove {
  my ($sName, $oClient, $aFrom, $aTo, $xRelPath, $aParams
     , $aExpectedActions) = @_;

  $aExpectedActions = $MOVE_ACTIONS unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  if (defined($xRelPath)) {
    my $aWcs = $aTo;
    my ($sRelPath, $bFile)= ref($xRelPath) ? @$xRelPath : ($xRelPath);
    $aTo = [ map { $_->getFullPathName($sRelPath, $bFile) } @$aWcs ];
  }

  $aParams = [] unless defined($aParams);
  my ($crCommit, $bForce, $bMoveAsChild, $bMakeParents, $hRevProps)
    = @$aParams;
  my $bMinimal = _isMinimal($aParams);

  my @aMove = $bMinimal
    ? ( sub { $oClient->move($_[0], $_[1]); }
        , sub { $oClient->move1_1($_[0], undef, $_[1]) }
        , sub { $oClient->move1_4($_[0], $_[1]) }
        , sub { $oClient->move1_5($_[0], $_[1]) }
        , sub { $oClient->move1_6($_[0], $_[1]) }
        , sub { $oClient->move1_7($_[0], $_[1]) }
     )
    : ( sub { $oClient->move($_[0], $_[1], $bForce); }
        , sub { $oClient->move1_1($_[0], undef, $_[1], $bForce) }
        , sub { $oClient->move1_4($_[0], $_[1], $bForce) }
        , sub { $oClient->move1_5($_[0], $_[1], $bForce, $bMoveAsChild
                , $bMakeParents, $hRevProps) }
        , sub { $oClient->move1_6($_[0], $_[1], $bForce, $bMoveAsChild
                , $bMakeParents, $hRevProps) }
        , sub { $oClient->move1_7($_[0], $_[1], $bMoveAsChild
                , $bMakeParents, $hRevProps, $crCommit) }
     );

  for my $i (0..$#$aFrom) {
    my $sFrom = $aFrom->[$i];
    next unless defined($sFrom);

    my $sTo = $aTo->[$i];
    my $sTest = "$sName:move$VERSION_SUFFIXES[$i]($sFrom => $sTo)";

    my $hFromStatus = $oClient->getStatus($sFrom);
    my $bDeleteWhenScheduled = (-d $sFrom) ? 0 : 1;

    okNotifyActions { $aMove[$i]->($sFrom, $sTo);
                     } $sTest, $aExpectedActions, 1;
    next unless $bVerify;

    okGetStatus("$sTest - verifying change in source status"
                , $oClient, $sFrom, $DEL_STATUS);
    is((-e $sFrom)?1:0, $bDeleteWhenScheduled?0:1
       , "$sTest - verifiying removal of source");

    okGetStatus("$sTest - verifying target status"
                , $oClient, $sTo, $COPY_STATUS);
    is((-e $sTo)?1:0, 1, "$sTest - verifiying existance of target");
  }
  return $aTo;
}

#--------------------------------------------------------------------

sub okNotifyActions(&$$;$) {
  my ($cr, $sTest, $aExpectedActions, $bDieOnUnexpectedException)=@_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  my $bOk=1;
  my $sRefExpect=ref($aExpectedActions);

  eval {
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    @aNotifications=();
    $cr->();

    if ($sRefExpect eq 'ARRAY') {
      if ($NOTIFYING) {
        my @aActions
          = map { $_->[$IDX_NOTIFY_ACTION] } @aNotifications;
        $bOk=is_deeply(\@aActions, $aExpectedActions
                       , "$sTest - verifying actions")
          or do {

            $aExpectedActions= [ map {
              $CLIENT_CLASS->getActionAsString($_)
            } @$aExpectedActions ];
            @aActions = map { $CLIENT_CLASS->getActionAsString($_)
                            } @aActions;
            local $"='; ';
            diag("\nGot actions= (@aActions)"
                 ."\nExpected actions: (@$aExpectedActions)"
                );
          };
      }
    } else {
      my $sError = 'exception expected but none thrown';
      $bOk=fail("$sTest: $sError");

      # failure to throw an exception may mean that an operation will
      # commit when it wasn't expected to, thereby throwing off the rev
      # counts.
      die $sError if ($bDieOnUnexpectedException);
    }
    return 1;

  } or do {
    my $e=$@;

    if ($sRefExpect eq 'ARRAY') {
      $bOk=fail("$sTest: unexpected exception: $e");
      if ($bDieOnUnexpectedException) {
        BAIL_OUT("remaining tests not applicable due to "
                 ."unexpected exception");
      }
    } elsif (defined($aExpectedActions) && ($aExpectedActions eq '')){
      pass("$sTest: exception thrown");
    } elsif (defined($aExpectedActions)) {
      $bOk=like($e, $aExpectedActions, "$sTest: verifying exception");
    } else {
      $@=$e; die;  #rethrow
    }
  };

  return $bOk;
}

#--------------------------------------------------------------------

sub okPropdel {
  my ($sName, $oClient, $aPaths, $aDelProps, $aParams
      , $hRemaining, $hExpectedStatus, $aExpectedActions) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  $aExpectedActions=[] unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  $aParams=[] unless defined($aParams);
  my ($crCommit, $iDepth, $bSkipChecks, $xBaseRev, $aChangeLists
      , $hRevProp) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams);

  my @aPropdel = $bMinimal
    ? ( sub { $oClient->propdel($_[1], $_[0]) }
      , sub { $oClient->propdel1_1($_[0],$_[1]) }
      , sub { $oClient->propdel1_4($_[0],$_[1]) }
      , sub { $oClient->propdel1_5($_[0],$_[1]) }
      , sub { $oClient->propdel1_6($_[0],$_[1]) }
      , sub { $oClient->propdel1_7($_[0],$_[1]) }
      )
    : ( sub { $oClient->propdel($_[1], $_[0], $bRecurse) }
      , sub { $oClient->propdel1_1($_[0],$_[1], $bRecurse) }
      , sub { $oClient->propdel1_4($_[0],$_[1], $bRecurse
              , $bSkipChecks) }
      , sub { $oClient->propdel1_5($_[0],$_[1], $iDepth
              , $bSkipChecks, $xBaseRev, $aChangeLists, $hRevProp) }
      , sub { $oClient->propdel1_6($_[0],$_[1], $iDepth
              , $bSkipChecks, $xBaseRev, $aChangeLists, $hRevProp) }
      , sub { $oClient->propdel1_7($_[0],$_[1], $iDepth
              , $bSkipChecks, $xBaseRev, $aChangeLists, $hRevProp
              , $crCommit) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:propdel$VERSION_SUFFIXES[$i]($sPath)";

    foreach my $k (@$aDelProps) {
      my $sSubtest = "$sTest: $k";
      okNotifyActions { $aPropdel[$i]->($k, $sPath);
                       } $sSubtest, $aExpectedActions, 1;
    }

    okGetStatus("$sTest - verifying target status"
                , $oClient, $sPath, $hExpectedStatus);
    next unless $bVerify;

    is_deeply($oClient->getPathProperties($sPath), $hRemaining
       , "$sTest - verifying deletion of properties");
  }
}

#--------------------------------------------------------------------

sub okPropertyHash {
  my ($hGot, $hExpected, $sTest) = @_;
  my $bOk=1;

  # make sure $hGot and $hExpected are of the same type
  if (!defined($hExpected)) {
    if (!defined($hGot)) {
      pass($sTest);  # both undefined, nothing to do
      return 1;
    }
    $bOk = 0;
  } elsif (ref($hGot) ne 'HASH') {
    $bOk = 0;
  }

  if (!$bOk) {
    fail($sTest);
    diag( "Got:      ".(defined($hGot)?$hGot:'undef')."\n"
          ."Expected: ".(defined($hExpected)?$hExpected:'undef')
          ."\n");
    return 0;
  }

  # don't include svn properties in extra properties
  my @aExtra = grep {
    (($_ =~ qr{^svn:}) || exists($hExpected->{$_})) ?0:1
  } keys %$hGot;

  if (@aExtra) {
    fail($sTest);
    if (scalar(@aExtra) == 1) {
      diag("Got an unexpected property: @aExtra");
    } else {
      diag("Got unexpected properties: @aExtra");
    }
    return 0;
  }

  # find a mismatch and print out the rest of the keys
  my @aGot;
  my @aExpected=keys %$hExpected;

  foreach my $k (keys %$hExpected) {

    if (!exists($hGot->{$k})) {
      fail($sTest);
      diag( "Got :      {$k}=>Does not exist\n"
           ."Expected:  {$k}=>".$hExpected->{$k}."\n");
      $bOk=0;
    } else {
      push @aGot, $k;
      if ($bOk && ($hExpected->{$k} ne $hGot->{$k})) {
        fail($sTest);
        diag( "Got:      {$k}=>".$hGot->{$k}."\n"
             ."Expected: {$k}=>".$hExpected->{$k}."\n");
        $bOk=0;
      }
    }
  }

  if (!$bOk) {
    diag("Got keys: (@aGot)\nExpected keys: (@aExpected)\n");
  }
  return $bOk;
}

#--------------------------------------------------------------------

sub okPropget {
  my ($sName, $oClient, $xPaths, $aParams
      , $iSetInRev, $hProps, $aExpectedActions) = @_;

  # if expected actions is not a [], then it is an error class or
  # regex for matching a string exception.

  $aExpectedActions=[] unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  my ($aPaths, $xPeg, $xRev) = ref($xPaths) ? @$xPaths : ($xPaths);
  my $bCommitted= defined($xPeg) && ($xPeg ne 'WORKING');

  $aParams = [] unless defined($aParams);
  my ($iDepth, $aChangeLists) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams, $xPeg, $xRev);

  my @aPropget = $bMinimal
    ? ( sub { $oClient->propget($_[0], $_[1]) }
      , sub { $oClient->propget1_1($_[1], $_[0]) }
      , sub { $oClient->propget1_4($_[1], $_[0]) }
      , sub { $oClient->propget1_5($_[1], $_[0]) }
      , sub { $oClient->propget1_6($_[1], $_[0]) }
      , sub { $oClient->propget1_7($_[1], $_[0]) }
      )
    : ( sub { $oClient->propget($_[0], $_[1], $xPeg) }
      , sub { $oClient->propget1_1($_[1], $_[0], $xPeg, $bRecurse) }
      , sub { $oClient->propget1_4($_[1], $_[0], $xPeg, $xRev
            , $bRecurse) }
      , sub { $oClient->propget1_5($_[1], $_[0], $xPeg, $xRev
            , $iDepth, $aChangeLists) }
      , sub { $oClient->propget1_6($_[1], $_[0], $xPeg, $xRev
            , $iDepth, $aChangeLists) }
      , sub { $oClient->propget1_7($_[1], $_[0], $xPeg, $xRev
            , $iDepth, $aChangeLists) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);

    while (my ($k,$v) = each(%$hProps)) {
      my $sTest
        = "$sName:propget$VERSION_SUFFIXES[$i]($sPath@"
          . (defined($xPeg)?$xPeg:'WORKING') .": $k=$v)";

      my @aGot;
      okNotifyActions { @aGot = $aPropget[$i]->($sPath, $k);
                       } $sTest, $aExpectedActions;
      next if ! $bVerify;

      my $sPegPath = $bCommitted
        ? $oClient->getRepositoryURL($sPath) : $sPath;

      is($aGot[0]->{$sPegPath}, $v
         , "$sTest - verifying value (locally)");
      if ($IDX_SVN1_4 < $i) {
        is($aGot[1], $iSetInRev
           , "$sTest - verifying revision (locally)");
      }

      if ($bCommitted) {
        okNotifyActions { @aGot = $aPropget[$i]->($sPegPath, $k);
                         } $sTest, $aExpectedActions;
        next if ! $bVerify;

        is($aGot[0]->{$sPegPath}, $v
           , "$sTest - verifying value (remotely)");
        if ($IDX_SVN1_4 < $i) {
          is($aGot[1], $iSetInRev
             , "$sTest - verifying revision (remotely)");
        }
      }
    }
  }
}

#--------------------------------------------------------------------

sub okProplist {
  my ($sName, $oClient, $xPaths, $aParams
     , $hNodes, $aExpectedActions) = @_;

  # if expected actions is not a [], then it is an error class or
  # regex for matching a string exception.

  $aExpectedActions=[] unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;


  my ($aPaths, $xPeg, $xRev) = ref($xPaths) ? @$xPaths : ($xPaths);
  my $bCommitted= defined($xPeg) && ($xPeg ne 'WORKING');

  $aParams = [] unless defined($aParams);
  my ($iDepth, $aChangeLists) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams, $xPeg, $xRev);

  my @aProplist = $bMinimal
    ? ( sub { $oClient->proplist($_[0]) }
      , sub { $oClient->proplist1_1($_[0]) }
      , sub { $oClient->proplist1_4($_[0]) }
      , sub { $oClient->proplist1_5($_[0], $xPeg, $xRev, $iDepth
            , $aChangeLists, $_[1]) }
      , sub { $oClient->proplist1_6($_[0], $xPeg, $xRev, $iDepth
            , $aChangeLists, $_[1]) }
      , sub { $oClient->proplist1_7($_[0], $xPeg, $xRev, $iDepth
            , $aChangeLists, $_[1]) }
      )
    : ( sub { $oClient->proplist($_[0], $xPeg, $bRecurse) }
      , sub { $oClient->proplist1_1($_[0], $xPeg, $bRecurse) }
      , sub { $oClient->proplist1_4($_[0], $xPeg, $xRev, $bRecurse) }
      , sub { $oClient->proplist1_5($_[0], $xPeg, $xRev, $iDepth
            , $aChangeLists, $_[1]) }
      , sub { $oClient->proplist1_6($_[0], $xPeg, $xRev, $iDepth
            , $aChangeLists, $_[1]) }
      , sub { $oClient->proplist1_7($_[0], $xPeg, $xRev, $iDepth
            , $aChangeLists, $_[1]) }
      );

  my %hGot;
  my $crVisit = sub { $hGot{$_[0]} = $_[1]; };


  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);

    # proplist requires repository URL with historical revisions
    # and working copy paths with working copy revisions
    # $aPaths is the working copy path, so we convert it.
    $sPath = $oClient->getRepositoryURL($sPath) if $bCommitted;

    my $sTest = "$sName:proplist$VERSION_SUFFIXES[$i]($sPath)";
    my $aNodes;

    %hGot=();
    okNotifyActions { $aNodes = $aProplist[$i]->($sPath, $crVisit);
                     } $sTest, $aExpectedActions;
    next unless $bVerify;

    if (($i <= $IDX_SVN1_4) && defined($aNodes) && scalar($aNodes)) {
       %hGot = map { $_->node_name() => $_->prop_hash() } @$aNodes;
    }

    is_deeply($hGot{$sPath}, $hNodes
       , "$sTest - verifying node properties (locally)");
  }
}

#--------------------------------------------------------------------

sub okPropset {
  my ($sName, $oClient, $aPaths, $hProps, $aParams
      , $hExpectedStatus, $aExpectedActions) = @_;

  $aExpectedActions=[] unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  $aParams = [] unless defined($aParams);
  my ($crCommit, $iDepth, $bSkipChecks, $xBaseRev, $aChangeLists
      , $hRevProp) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams);

  my @aPropset = $bMinimal
    ? ( sub { $oClient->propset($_[2], $_[0],$_[1]) }
      , sub { $oClient->propset1_1($_[0],$_[1], $_[2]) }
      , sub { $oClient->propset1_4($_[0],$_[1], $_[2]) }
      , sub { $oClient->propset1_5($_[0],$_[1], $_[2]) }
      , sub { $oClient->propset1_6($_[0],$_[1], $_[2]) }
      , sub { $oClient->propset1_7($_[0],$_[1], $_[2]) }
      )
    : ( sub { $oClient->propset($_[2], $_[0],$_[1], $bRecurse) }
      , sub { $oClient->propset1_1($_[0],$_[1], $_[2], $bRecurse) }
      , sub { $oClient->propset1_4($_[0],$_[1], $_[2], $bRecurse
              , $bSkipChecks) }
      , sub { $oClient->propset1_5($_[0],$_[1], $_[2], $iDepth
              , $bSkipChecks, $xBaseRev, $aChangeLists, $hRevProp) }
      , sub { $oClient->propset1_6($_[0],$_[1], $_[2], $iDepth
              , $bSkipChecks, $xBaseRev, $aChangeLists, $hRevProp) }
      , sub { $oClient->propset1_7($_[0],$_[1], $_[2], $iDepth
              , $bSkipChecks, $xBaseRev, $aChangeLists, $hRevProp
              , $crCommit) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);

    my $sTest = "$sName:propset$VERSION_SUFFIXES[$i]($sPath)";

    while (my ($k,$v) = each(%$hProps)) {
      my $sSubtest = "$sTest, $k=$v";
      okNotifyActions { $aPropset[$i]->($k, $v, $sPath);
                       } $sSubtest, $aExpectedActions, 1;
      next unless $bVerify;

      is($oClient->getPathProperty($sPath, $k), $v
         , "$sSubtest - verifying value");
    }

    okGetStatus($sTest, $oClient, $sPath, $hExpectedStatus);
  }
}

#--------------------------------------------------------------------

sub okRelocate {
  my ($sName, $oClient, $aWcs, $aToRepos, $aParams
      , $aExpectedActions) = @_;
  $aExpectedActions=[] unless defined($aExpectedActions);

  $aParams = [] unless defined($aParams);
  my ($bRecurse, $bIgnoreExternals) = @$aParams;
  my $bMinimal = _isMinimal($aParams);

  my @aRelocate = $bMinimal
    ? ( sub { $oClient->relocate($_[0], $_[1], $_[2]) }
      , sub { $oClient->relocate1_1($_[0], $_[1], $_[2]) }
      , sub { $oClient->relocate1_4($_[0], $_[1], $_[2]) }
      , sub { $oClient->relocate1_5($_[0], $_[1], $_[2]) }
      , sub { $oClient->relocate1_6($_[0], $_[1], $_[2]) }
      , sub { $oClient->relocate1_7($_[0], $_[1], $_[2]) }
      )
    : ( sub { $oClient->relocate($_[0], $_[1], $_[2], $bRecurse) }
      , sub { $oClient->relocate1_1($_[0], $_[1], $_[2], $bRecurse) }
      , sub { $oClient->relocate1_4($_[0], $_[1], $_[2], $bRecurse) }
      , sub { $oClient->relocate1_5($_[0], $_[1], $_[2], $bRecurse) }
      , sub { $oClient->relocate1_6($_[0], $_[1], $_[2], $bRecurse) }
      , sub { $oClient->relocate1_7($_[0], $_[1], $_[2]
              , $bIgnoreExternals) }
      );

  for my $i (0..$#$aWcs) {
    my $sPath = $aWcs->[$i]->getRoot();
    next unless defined($sPath);

    my $sTest = "$sName:relocate$VERSION_SUFFIXES[$i]($sPath)";
    my $sFrom = $oClient->getRepositoryURL($sPath);
    my $sTo   = $aToRepos->[$i];

    okNotifyActions { $aRelocate[$i]->($sPath, $sFrom, $sTo);
                     } $sTest, $aExpectedActions, 1;

    is($oClient->getRepositoryURL($sPath), $sTo
       , "$sTest - verifying repository path");
    is($oClient->getRepositoryRootURL($sPath), $sTo
       , "$sTest - verifying repository root");

  }
}

#--------------------------------------------------------------------

sub okResolved {
  my ($sName, $oClient, $aPaths, $aParams, $aExpectedActions) = @_;

  $aParams=[] unless defined($aParams);
  my ($bRecurse) = @$aParams;
  my $bMinimal = _isMinimal($aParams);

  my @aResolved = $bMinimal
    ? ( sub { $oClient->resolved($_[0]) }
      , sub { $oClient->resolved1_1($_[0]) }
      , sub { $oClient->resolved1_4($_[0]) }
      , sub { $oClient->resolved1_5($_[0]) }
      , sub { $oClient->resolved1_6($_[0]) }
      , sub { $oClient->resolved1_7($_[0]) }
      )
    : ( sub { $oClient->resolved($_[0], $bRecurse) }
      , sub { $oClient->resolved1_1($_[0], $bRecurse) }
      , sub { $oClient->resolved1_4($_[0], $bRecurse) }
      , sub { $oClient->resolved1_5($_[0], $bRecurse) }
      , sub { $oClient->resolved1_6($_[0], $bRecurse) }
      , sub { $oClient->resolved1_7($_[0], $bRecurse) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:resolved$VERSION_SUFFIXES[$i]($sPath)";
    okNotifyActions { $aResolved[$i]->($sPath);
                     } $sTest, $aExpectedActions, 1;
  }
}

#--------------------------------------------------------------------

sub okRevert {
  my ($sName, $oClient, $aPaths, $aParams, $hExpectedStatus
      , $bExists, $aExpectedActions) = @_;

  $aExpectedActions=$REVERT_ACTIONS unless defined($aExpectedActions);


  $aParams=[] unless defined($aParams);
  my ($iDepth, $aChangeLists) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams);

  my @aRevert = $bMinimal
    ? ( sub { $oClient->revert($_[0]) }
      , sub { $oClient->revert1_1($_[0]) }
      , sub { $oClient->revert1_4($_[0]) }
      , sub { $oClient->revert1_5($_[0]) }
      , sub { $oClient->revert1_6($_[0]) }
      , sub { $oClient->revert1_7($_[0]) }
      )
    : ( sub { $oClient->revert($_[0], $bRecurse) }
      , sub { $oClient->revert1_1($_[0], $bRecurse) }
      , sub { $oClient->revert1_4($_[0], $bRecurse) }
      , sub { $oClient->revert1_5($_[0], $iDepth, $aChangeLists) }
      , sub { $oClient->revert1_6($_[0], $iDepth, $aChangeLists) }
      , sub { $oClient->revert1_7($_[0], $iDepth, $aChangeLists) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);

    my $sTest = "$sName:revert$VERSION_SUFFIXES[$i]($sPath)";
    okNotifyActions { $aRevert[$i]->($sPath);
                     } $sTest, $aExpectedActions, 1;

    okGetStatus($sTest, $oClient, $sPath, $hExpectedStatus);
    is((-e $sPath)?1:0, $bExists
       , "$sTest - verifying "
       .($bExists?'existance':'non-existance'));
  }
}

#--------------------------------------------------------------------

sub okRevprop_delete {
  my ($sName, $oClient, $xPaths, $hProps, $aParams
      , $iSetInRev, $hRemaining, $aExpectedActions) = @_;

  # if expected actions is not a [], then it is an error class or
  # regex for matching a string exception.

  $aExpectedActions=[] unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  my ($aPaths, $xPeg, $xRev) = ref($xPaths) ? @$xPaths : ($xPaths);

  $aParams = [] unless defined($aParams);
  my ($bForce) = @$aParams;
  my $bMinimal = _isMinimal($aParams, $xPeg);

  my @aRevprop_delete = $bMinimal
    ? ( sub { $oClient->revprop_delete($_[0], $_[1]) }
      , sub { $oClient->revprop_delete1_1($_[1], $_[0]) }
      , sub { $oClient->revprop_delete1_4($_[1], $_[0]) }
      , sub { $oClient->revprop_delete1_5($_[1], $_[0]) }
      , sub { $oClient->revprop_delete1_6($_[1], $_[2], $_[0]) }
      , sub { $oClient->revprop_delete1_7($_[1], $_[2], $_[0]) }
      )
    : ( sub { $oClient->revprop_delete($_[0], $_[1], $xPeg, $bForce) }
      , sub { $oClient->revprop_delete1_1($_[1]
            , $_[0], $xPeg, $bForce) }
      , sub { $oClient->revprop_delete1_4($_[1]
            , $_[0], $xPeg, $bForce) }
      , sub { $oClient->revprop_delete1_5($_[1]
            , $_[0], $xPeg, $bForce) }
      , sub { $oClient->revprop_delete1_6($_[1], $_[2]
            , $_[0], $xPeg, $bForce) }
      , sub { $oClient->revprop_delete1_7($_[1], $_[2]
            , $_[0], $xPeg, $bForce) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);

    my $sTest
      = "$sName:revprop_delete$VERSION_SUFFIXES[$i]($sPath)";

    while (my ($k,$v) = each(%$hProps)) {
      my $sSubtest = "$sTest: $k=$v";

      my $vOld = $oClient->revprop_get($sPath, $k, $xPeg);
      my $iGotRev;
      okNotifyActions {
        $iGotRev = $aRevprop_delete[$i]->($sPath, $k, $vOld);
      } $sSubtest, $aExpectedActions;

      if ($bVerify) {
        is($iGotRev, $iSetInRev
           , "$sSubtest - verifying set-in-revsion");
      }
    }

    if ($bVerify) {
      my $hGot = $oClient->getRevisionProperties($sPath, $xPeg);
      okPropertyHash($hGot, $hRemaining
         , "$sTest - verifying deletion of properties");
    }
  }
}

#--------------------------------------------------------------------

sub okRevprop_get {
  my ($sName, $oClient, $xPaths, $aParams
      , $iSetInRev, $hProps, $aExpectedActions) = @_;

  # if expected actions is not a [], then it is an error class or
  # regex for matching a string exception.

  $aExpectedActions=[] unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  $aParams = [] unless defined($aParams);
  my ($aPaths, $xPeg, $xRev) = ref($xPaths) ? @$xPaths : ($xPaths);
  $aParams = [] unless defined($aParams);
  my $bMinimal = _isMinimal($aParams, $xPeg);

  my @aRevprop_get = $bMinimal
    ?( sub { $oClient->revprop_get($_[0], $_[1]) }
      , sub { $oClient->revprop_get1_1($_[1], $_[0]) }
      , sub { $oClient->revprop_get1_4($_[1], $_[0]) }
      , sub { $oClient->revprop_get1_5($_[1], $_[0]) }
      , sub { $oClient->revprop_get1_6($_[1], $_[0]) }
      , sub { $oClient->revprop_get1_7($_[1], $_[0]) }
      )
    : ( sub { $oClient->revprop_get($_[0], $_[1], $xPeg) }
      , sub { $oClient->revprop_get1_1($_[1], $_[0], $xPeg) }
      , sub { $oClient->revprop_get1_4($_[1], $_[0], $xPeg) }
      , sub { $oClient->revprop_get1_5($_[1], $_[0], $xPeg) }
      , sub { $oClient->revprop_get1_6($_[1], $_[0], $xPeg) }
      , sub { $oClient->revprop_get1_7($_[1], $_[0], $xPeg) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);

    while (my ($k,$v) = each(%$hProps)) {
      my $sTest
        = "$sName:revprop_get$VERSION_SUFFIXES[$i]($sPath: $k=$v)";

      my @aGot;
      okNotifyActions { @aGot = $aRevprop_get[$i]->($sPath, $k);
                       } $sTest, $aExpectedActions;
      next unless $bVerify;

      is($aGot[1], $iSetInRev, "$sTest - verifying revision");
      is($aGot[0], $v, "$sTest - verifying value");
    }
  }
}

#--------------------------------------------------------------------

sub okRevprop_list {
  my ($sName, $oClient, $xPaths, $aParams
     , $iSetInRev, $hProps, $aExpectedActions) = @_;

  # if expected actions is not a [], then it is an error class or
  # regex for matching a string exception.

  $aExpectedActions=[] unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  my ($aPaths, $xPeg, $xRev) = ref($xPaths) ? @$xPaths : ($xPaths);

  $aParams = [] unless defined($aParams);
  my $bMinimal = _isMinimal($aParams, $xPeg);


  my @aRevprop_list = $bMinimal
    ? ( sub { $oClient->revprop_list($_[0]) }
      , sub { $oClient->revprop_list1_1($_[0]) }
      , sub { $oClient->revprop_list1_4($_[0]) }
      , sub { $oClient->revprop_list1_5($_[0]) }
      , sub { $oClient->revprop_list1_6($_[0]) }
      , sub { $oClient->revprop_list1_7($_[0]) }
      )
    : ( sub { $oClient->revprop_list($_[0], $xPeg) }
      , sub { $oClient->revprop_list1_1($_[0], $xPeg) }
      , sub { $oClient->revprop_list1_4($_[0], $xPeg) }
      , sub { $oClient->revprop_list1_5($_[0], $xPeg) }
      , sub { $oClient->revprop_list1_6($_[0], $xPeg) }
      , sub { $oClient->revprop_list1_7($_[0], $xPeg) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);

    my $sTest = "$sName:revprop_list$VERSION_SUFFIXES[$i]($sPath)";

    my @aGot;
    okNotifyActions { @aGot = $aRevprop_list[$i]->($sPath);
                     } $sTest, $aExpectedActions;
    next unless $bVerify;

    okPropertyHash($aGot[0], $hProps
       , "$sTest - verifying property-value list");
    is($aGot[1], $iSetInRev, "$sTest - verifying set-in-revision");
  }
}

#--------------------------------------------------------------------

sub okRevprop_set {
  my ($sName, $oClient, $xPaths, $hProps, $aParams
      , $iSetInRev, $hAllProps, $aExpectedActions) = @_;

  # if expected actions is not a [], then it is an error class or
  # regex for matching a string exception.

  $aExpectedActions=[] unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  my ($aPaths, $xPeg, $xRev) = ref($xPaths) ? @$xPaths : ($xPaths);

  $aParams = [] unless defined($aParams);
  my ($bForce) = @$aParams;
  my $bMinimal = _isMinimal($aParams, $xPeg, $xRev);

  my @aRevprop_set = $bMinimal
    ? ( sub { $oClient->revprop_set($_[0], $_[1], $xPeg, $_[2]) }
      , sub { $oClient->revprop_set1_1($_[1],$_[2], $_[0]) }
      , sub { $oClient->revprop_set1_4($_[1],$_[2], $_[0]) }
      , sub { $oClient->revprop_set1_5($_[1],$_[2], $_[0]) }
      , sub { $oClient->revprop_set1_6($_[1],$_[2], $_[3], $_[0]) }
      , sub { $oClient->revprop_set1_7($_[1],$_[2], $_[3], $_[0]) }
      )
    : ( sub { $oClient->revprop_set($_[0], $_[1], $xPeg, $_[2]
            , $bForce) }
      , sub { $oClient->revprop_set1_1($_[1],$_[2]
            , $_[0], $xPeg, $bForce) }
      , sub { $oClient->revprop_set1_4($_[1],$_[2]
            , $_[0], $xPeg, $bForce) }
      , sub { $oClient->revprop_set1_5($_[1],$_[2]
            , $_[0], $xPeg, $bForce) }
      , sub { $oClient->revprop_set1_6($_[1],$_[2], $_[3]
            , $_[0], $xPeg, $bForce) }
      , sub { $oClient->revprop_set1_7($_[1],$_[2], $_[3]
            , $_[0], $xPeg, $bForce) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);

    my $sTest = "$sName:revprop_set$VERSION_SUFFIXES[$i]($sPath)";

    while (my ($k,$v) = each(%$hProps)) {
      my $vOld = $oClient->revprop_get($sPath, $k, $xPeg);
      my $sSubtest = "$sTest: $k=$v";
      my $iGotRev;
      okNotifyActions {
        $iGotRev = $aRevprop_set[$i]->($sPath, $k, $v, $vOld);
      } $sSubtest, $aExpectedActions;
      next unless $bVerify;

      is($iGotRev, $iSetInRev, "$sSubtest: verifying set revision");
    }
    next unless $bVerify;

    my $hGot = $oClient->getRevisionProperties($sPath, $xPeg);
    okPropertyHash($hGot, $hAllProps
       , "$sTest - verifying property-value list");
  }
}

#--------------------------------------------------------------------

sub okShift1($$$$) {
  my ($sName, $crShift, $xArg1, $xExpected) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;
  return okShiftMany($sName, $crShift, [$xArg1], [$xExpected]);
}

#--------------------------------------------------------------------

sub okShiftMany($$$$;$) {
  my ($sName, $crShift, $aArgs, $aExpected, $bOptional) = @_;
  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $aInput = [ $aArgs && scalar(@$aArgs) ? @$aArgs : undef
                 , 'STOP'
               ];
  my $sCall = _makeCall($sName, $aInput);

  is_deeply([ &$crShift($aInput) ], $aExpected, "$sCall - retval");
  is_deeply($aInput, ['STOP'], "$sCall - remainder");

  if ($bOptional) {
    my $rEnd = \'STOP';
    for (my $i=0; $i <= $#$aArgs; $i++) {
      last if defined($aArgs->[$#$aArgs-$i]);

      $aInput = $i > $#$aArgs
        ? [ $rEnd ] : [ @{$aArgs}[0..($#$aArgs-$i-1)], $rEnd ];
      $sCall = _makeCall($sName, $aInput);
      is_deeply([ &$crShift($aInput) ], $aExpected
                  , "$sCall - retval");
      is_deeply($aInput, [$rEnd], "$sCall - remainder");
    }
  }
}

#--------------------------------------------------------------------

sub okStatus {
  my ($sName, $oClient, $xPath, $aParams, $hStatus
      , $aExpectedActions, $aOut) = @_;

  $aExpectedActions = [] unless defined($aExpectedActions);

  my $iVisitCount = defined($aOut) ? scalar(@$aOut) : 0;
  my $sOut='';
  if (defined($aOut)) {
    foreach my $aLine (@$aOut) {
      $sOut .= sprintf("%-11s %-11s %s\n", @$aLine);
    }
  }

  # $xPath may be: $sPath
  #                [ $sPath, $xPeg, $xRev]
  #                [ $aPaths, $xPeg, $xRev]

  my ($aPaths, $xPeg, $xRev) = ref($xPath) ? @$xPath : ($xPath);
  $aPaths = [ $aPaths ] if ! ref($aPaths);


  $aParams=[] unless defined($aParams);
  my ($bRecurse, $bAll, $bUpdate, $bNoIgnore, $bSkipExternals
     , $aChangeLists) = @$aParams;
  my $bMinimal = _isMinimal($aParams, $xPeg, $xRev);

  my $bOk=1;
  my $sMsg='';
  my @aVisits;
  my $crVisit = sub {
    my ($sWc, $oStatus, $oPool) = @_;

    #Note: only 1.2+ API (status2) supports flag to indicate whether
    #file is locked in the repository. The locked flag returned by
    #locked() really should be frozen or interrupted. It refers to
    #file that are "locked" because their modifications have only
    #been partially stored in the repository.

    my $iTextStatus = $oStatus->text_status();
    my $iPropStatus = $oStatus->prop_status();
    my $bInterrupted = $oStatus->locked();

    push @aVisits, [$sWc, $iTextStatus, $iPropStatus, $bInterrupted];

    if ($NOISY) {
      my $oEntry = $oStatus->entry();
      my $sEntry = '';
      if ($oEntry) {
        my $sName = $oEntry->name();
        $sName = 'undef' unless defined($sName);

        my $sUuid = $oEntry->uuid();
        $sUuid = 'undef' unless defined($sUuid);
        $sEntry = "name=" .  $sName
          . " rev=" . $oEntry->revision()
          . " url=" . $oEntry->url()
          . " repos=" . $oEntry->repos()
          . " uuid=" . $sUuid
          . " kind=" . $oEntry->kind()
          . " schedule="
          . $CLIENT_CLASS->getScheduledOpAsString($oEntry->schedule())
          . " etc, etc, etc...";
      };

      print STDERR "status: <$sWc> entry=<$sEntry"
        . "> text=<" . $CLIENT_CLASS->getStatusAsString($iTextStatus)
        . "> props=<" . $CLIENT_CLASS->getStatusAsString($iPropStatus)
        . "> interupted=<" . $bInterrupted
        . "> copied=<" . $oStatus->copied()
        . "> switched=<" . $oStatus->switched()
        . "> repos text=<". $CLIENT_CLASS
           ->getStatusAsString($oStatus->repos_text_status())
        . "> repo props=<" . $CLIENT_CLASS
          ->getStatusAsString($oStatus->repos_prop_status())
        . ">\n";
    }


    return unless $bOk;  # only capture errors once

    if (!defined($sWc) || ref($sWc) || !length($sWc)) {
      $bOk=0;
      $sWc=defined($sWc) ? "'$sWc'" : 'undef';
      $sMsg .= "path: expected non-empty string, got <$sWc>\n";
    }
    if (!defined($oStatus)
        || ref($oStatus) ne '_p_svn_client_status_t') {
      $oStatus=defined($oStatus) ? "'$oStatus'" : 'undef';
      $sMsg .= 'status object: expected reference to svn_status_t'
        . ", got <$oStatus>\n";
    }
    if (!defined($oPool) || ref($oPool) ne '_p_apr_pool_t') {
      $oPool=defined($oPool) ? "'$oPool'" : 'undef';
      $sMsg .= 'pool object: expected reference to svn_pool_t'
        . ", got <$oPool>\n";
    }
  };

  my @aStatus = $bMinimal
    ? ( sub { $oClient->status($_[0], $crVisit); }
      , sub { $oClient->status1_1($_[0], $crVisit); }
      , sub { $oClient->status1_4($_[0], $crVisit); }
      , sub { $oClient->status1_5($_[0], $crVisit); }
      , sub { $oClient->status1_6($_[0], $crVisit); }
      , sub { $oClient->status1_7($_[0], $xPeg, $bRecurse
                  , $bAll, $bUpdate, $bNoIgnore, $bSkipExternals
                  , $aChangeLists, $crVisit); }
     )
    : ( sub { $oClient->status($_[0], $crVisit, $bRecurse
                  , $bUpdate, $xPeg, $bAll, $bNoIgnore); }
      , sub { $oClient->status1_1($_[0], $xPeg, $crVisit, $bRecurse
                  , $bAll, $bUpdate, $bNoIgnore); }
      , sub { $oClient->status1_4($_[0], $xPeg, $crVisit, $bRecurse
                  , $bAll, $bUpdate, $bNoIgnore, $bSkipExternals); }
      , sub { $oClient->status1_5($_[0], $xPeg, $crVisit, $bRecurse
                  , $bAll, $bUpdate, $bNoIgnore, $bSkipExternals
                  , $aChangeLists); }
      , sub { $oClient->status1_6($_[0], $xPeg, $crVisit, $bRecurse
                  , $bAll, $bUpdate, $bNoIgnore, $bSkipExternals
                  , $aChangeLists); }
      , sub { $oClient->status1_7($_[0], $xPeg, $bRecurse
                  , $bAll, $bUpdate, $bNoIgnore, $bSkipExternals
                  , $aChangeLists, $crVisit); }
     );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:status$VERSION_SUFFIXES[$i]($sPath)";

    SKIP:
      {
        if ($SKIP_SWIG_BUGS && ($i == 2)) {
          my $sBug ="status: svn_client_status2: visitor "
            ."thunk undefined in SWIG-Perl";
          $SWIG_BINDING_BUGS{$sBug}++;
          local $TODO = "SWIG binding bug: need to report\n\t$sBug";
          skip $sTest, 3;
        }

        $bOk = 1;
        $sMsg ='';
        @aVisits=();
        okNotifyActions { $aStatus[$i]->($sPath);
                         } $sTest, $aExpectedActions;
        is(scalar(@aVisits), $iVisitCount
           , "$sTest - verifying visit count");
        ok($bOk, "$sTest - verifying callback parameters")
          or diag($sMsg);
      }


    if (!defined($xPeg) || ($xPeg eq 'WORKING')) {
      # getStatus()
      okGetStatus($sTest, $oClient, $sPath, $hStatus);

      # printStatus()
      my $sBufOut='';
      open(my $fhOut, '>', \$sBufOut);
      $oClient->printStatus($sPath, $fhOut);
      is($sBufOut, $sOut, "$sTest - verifying printStatus");
    }
  }
}

#--------------------------------------------------------------------

sub okSwitch {
  my ($sName, $oClient, $aFrom, $xToRepos, $sBranch, $aParams
      , $aExpectedActions) = @_;

  $aExpectedActions=$UPDATE_ACTIONS unless defined($aExpectedActions);

  my ($aToRepos, $xPeg, $xRev) = ref($xToRepos) eq 'ARRAY'
    ? @$xToRepos : ($xToRepos);

  $aParams = [] unless defined($aParams);
  my ($iDepth, $bDepthIsSticky, $bIgnoreExternals
     , $bAllowUnversionedObstructions) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams, $xPeg, $xRev);

  my @aSwitch = $bMinimal
    ? ( sub { $oClient->switch($_[0], $_[1]) }
      , sub { $oClient->switch1_1($_[0], $_[1]) }
      , sub { $oClient->switch1_4($_[0], $_[1]) }
      , sub { $oClient->switch1_5($_[0], $_[1]) }
      , sub { $oClient->switch1_6($_[0], $_[1]) }
      , sub { $oClient->switch1_7($_[0], $_[1]) }
      )
    : ( sub { $oClient->switch($_[0], $_[1], $xPeg, $bRecurse) }
      , sub { $oClient->switch1_1($_[0], $_[1], $xPeg, $bRecurse) }
      , sub { $oClient->switch1_4($_[0], $_[1], $xPeg, $bRecurse) }
      , sub { $oClient->switch1_5($_[0], $_[1], $xPeg, $xRev
            , $iDepth, $bDepthIsSticky, $bIgnoreExternals
            , $bAllowUnversionedObstructions) }
      , sub { $oClient->switch1_6($_[0], $_[1], $xPeg, $xRev
            , $iDepth, $bDepthIsSticky, $bIgnoreExternals
            , $bAllowUnversionedObstructions) }
      , sub { $oClient->switch1_7($_[0], $_[1], $xPeg, $xRev
            , $iDepth, $bDepthIsSticky, $bIgnoreExternals
            , $bAllowUnversionedObstructions) }
      );

  for my $i (0..$#$aFrom) {
    my $sFrom = $aFrom->[$i];
    next unless defined($sFrom);

    my $oTo   = $aToRepos->[$i];
    my $sTo = File::Spec->rel2abs($sBranch, $oTo->getRoot());
    $sTo= URI::file->new($sTo)->canonical()->as_string();

    my $sTest = "$sName:switch$VERSION_SUFFIXES[$i]($sFrom->$sTo)";

    okNotifyActions { $aSwitch[$i]->($sFrom, $sTo);
                     } $sTest, $aExpectedActions, 1;

    is($oClient->getRepositoryURL($sFrom), $sTo
       , "$sTest - verifying repository path");
  }
}

#--------------------------------------------------------------------

sub okUnlock {
  my ($sName, $oClient, $aPaths, $aParams, $aExpectedActions) = @_;

  $aExpectedActions = [] unless defined($aExpectedActions);

  $aParams = [] unless defined($aParams);
  my ($bBreakLock) = @$aParams;
  my $bMinimal = _isMinimal($aParams);

  my @aUnlock = $bMinimal
    ? ( sub { $oClient->unlock($_[0]) }
      , sub { $oClient->unlock1_1($_[0]) }
      , sub { $oClient->unlock1_4($_[0]) }
      , sub { $oClient->unlock1_5($_[0]) }
      , sub { $oClient->unlock1_6($_[0]) }
      , sub { $oClient->unlock1_7($_[0]) }
      )
    : ( sub { $oClient->unlock($_[0], $bBreakLock) }
      , sub { $oClient->unlock1_1($_[0], $bBreakLock) }
      , sub { $oClient->unlock1_4($_[0], $bBreakLock) }
      , sub { $oClient->unlock1_5($_[0], $bBreakLock) }
      , sub { $oClient->unlock1_6($_[0], $bBreakLock) }
      , sub { $oClient->unlock1_7($_[0], $bBreakLock) }
      );

  for my $i (0..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:unlock$VERSION_SUFFIXES[$i]($sPath)";
    okNotifyActions { $aUnlock[$i]->($sPath);
                     } $sTest, $aExpectedActions, 1;
    is($oClient->isLocked($sPath), 0
       , "$sName - verifying lock status");
  }
}

#--------------------------------------------------------------------

sub okUpdate {
  my ($sName, $oClient, $xPath, $aParams, $iExpectedRev
      , $aExpectedActions) = @_;

  $aExpectedActions = $UPDATE_ACTIONS
    unless defined($aExpectedActions);
  my $bVerify = ref($aExpectedActions) eq 'ARRAY' ?1:0;

  # $xPath may be: $sPath
  #                [ $sPath, $xPeg, $xRev]
  #                [ $aPaths, $xPeg, $xRev]

  my ($aPaths, $xPeg, $xRev) = ref($xPath) ? @$xPath : ($xPath);
  $aPaths = [ $aPaths ] if ! ref($aPaths);

  $aParams = [] unless defined($aParams);
  my ($iDepth, $bDepthIsSticky, $bSkipExternals
      , $bAllowUnversionedObstructions, $bMakeParents) = @$aParams;
  my $bRecurse = !defined($iDepth) ? undef : ($iDepth? 1 : 0);
  my $bMinimal = _isMinimal($aParams, $xPeg, $xRev);

  my @aUpdate = $bMinimal
    ? ( sub { $oClient->update($_[0]) }
      , sub { $oClient->update1_1($_[0]) }
      , sub { $oClient->update1_4($_[0]); }
      , sub { $oClient->update1_5($_[0]); }
      , sub { $oClient->update1_6($_[0]); }
      , sub { $oClient->update1_7($_[0]);}
      )
    : ( sub { $oClient->update($_[0], $xPeg, $bRecurse) }
      , sub { $oClient->update1_1($_[0], $xPeg, $bRecurse
              , $bSkipExternals) }
      , sub { $oClient->update1_4($_[0], $xPeg, $iDepth
              , $bDepthIsSticky, $bSkipExternals
              , $bAllowUnversionedObstructions); }
      , sub { $oClient->update1_5($_[0], $xPeg, $iDepth
              , $bDepthIsSticky, $bSkipExternals
              , $bAllowUnversionedObstructions); }
      , sub { $oClient->update1_6($_[0], $xPeg, $iDepth
              , $bDepthIsSticky, $bSkipExternals
              , $bAllowUnversionedObstructions); }
      , sub { $oClient->update1_7($_[0], $xPeg, $iDepth
              , $bDepthIsSticky, $bSkipExternals
              , $bAllowUnversionedObstructions, $bMakeParents);}
      );

  for my $i (0..$IDX_SVN1_4) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:update$VERSION_SUFFIXES[$i]($sPath)";
    my $iGotRev;

    if ($SKIP_SWIG_BUGS && ($i == $IDX_SVN1_4)) {
      my $sBug="update: svn_client_update2: parameter1 not "
        ."converted to return value by SWIG";
      $SWIG_BINDING_BUGS{$sBug}++;
      #local $TODO = "SWIG binding bug: need to report\n\t$sBug";

      # use older update method, so that at least the update
      # happens
      okNotifyActions { $iGotRev = $aUpdate[$i-1]->($sPath);
                       } $sTest, $aExpectedActions;
    } else {
      okNotifyActions { $iGotRev = $aUpdate[$i]->($sPath);
                       } $sTest, $aExpectedActions;
    }

    next unless $bVerify;
    is($iGotRev, $iExpectedRev, "$sTest - verifying revision");
  }

  my $aExpectedRevs = [ ($iExpectedRev) x scalar(@$aPaths) ];
  for my $i (3..$#$aPaths) {
    my $sPath = $aPaths->[$i];
    next unless defined($sPath);
    my $sTest = "$sName:update$VERSION_SUFFIXES[$i]($sPath)";
    my $aRevs;

    okNotifyActions { $aRevs = $aUpdate[$i]->($sPath);
                    } $sTest, $aExpectedActions;
    next unless $bVerify;

    is_deeply($aRevs, $aExpectedRevs, "$sTest - verifying revisions");
  }
}

#--------------------------------------------------------------------

sub testAuthentication {
  my ($sName, $oClient) = @_;
  my $sTest="$sName: testAuthentication";
  my $sSubtest;
  my @aGot;

  #--------------------------------------
  # with undef
  #--------------------------------------

  @aGot=$oClient->configureAuthentication();
  is_deeply(\@aGot, [$SVN::Friendly::Client::SILENT_AUTH_BATON,[]]
     , "$sTest - setAuthentication(undef)")
    or diag("got=(@aGot)\n");

  #--------------------------------------
  # with an authentication baton
  #--------------------------------------

  my $aProviders = [ SVN::Client::get_username_provider()
                     , SVN::Client::get_simple_provider() ];
  my $oBaton = SVN::Core::auth_open($aProviders);
  @aGot = $oClient->configureAuthentication($oBaton);

  is_deeply( \@aGot, [ $oBaton, []], "$sTest: baton");

  #--------------------------------------
  # with a hash
  #--------------------------------------

  okAuthentication($sTest.': emptyHash'
    , [$oClient->configureAuthentication({})],[]);
  okAuthentication($sTest.': retries'
    , [$oClient->configureAuthentication({retries=>10})],[]);

  my $hAuth = {};
  my $crUserName    = sub { print "username";     };
  my $crUserNamePw  = sub { print "username_pw"   };
  my $crServer      = sub { print "ssl_sever"     };
  my $crClient      = sub { print "ssl_client";   };
  my $crClientPw    = sub { print "ssl_client_pw" };

  $hAuth->{providers}
    = [ $oClient->SSL_SERVER
        , $oClient->SSL_CLIENT
        , $oClient->SSL_CLIENT_PW
        , $oClient->USERNAME
        , $oClient->USERNAME_PW
      ];
  $hAuth->{username}      = [ $crUserName, undef];
  $hAuth->{username_pw}   = [ $crUserNamePw, 0];
  $hAuth->{ssl_server}    = [ $crServer, 1];
  $hAuth->{ssl_client}    = [ $crClient ];
  $hAuth->{ssl_client_pw} = $crClientPw;

  okAuthentication($sTest.': hash=prompted w/ custom order'
    , [$oClient->configureAuthentication($hAuth)]
    , [ $crServer, $crClient, $crClientPw
        , $crUserName, $crUserNamePw]);

  $hAuth->{simple} = $hAuth->{username_pw};
  delete $hAuth->{username_pw};
  okAuthentication($sTest.': hash=simple instead of username_pw'
    , [$oClient->configureAuthentication($hAuth)]
    , [ $crServer, $crClient, $crClientPw
        , $crUserName, $crUserNamePw]);

  #--------------------------------------
  # with a provider array
  #--------------------------------------

  $aProviders
    = [ SVN::Client::get_username_provider()
        , SVN::Client::get_username_prompt_provider($crUserName,3) ];
  okAuthentication("$sTest: array"
    , [ $oClient->configureAuthentication($aProviders) ]
    , [ $crUserName ]);

}

#--------------------------------------------------------------------

sub okAuthentication {
  my ($sTest, $aGot, $aCallbacks) = @_;
  is(ref($aGot->[0]), '_p_svn_auth_baton_t'
     , "$sTest - verifying baton");

  my @aGotCallbacks=map { $$_ } @{$aGot->[1]};
  is_deeply(\@aGotCallbacks, $aCallbacks
      , "$sTest - verifying callbacks");
}

#--------------------------------------------------------------------

sub testNewClient {
  my ($sName, $aaParams, $hProperties) = @_;
  my $sContext = 'testNewClient';
  my $sClass   = $TEST_CLASS;
  my $oClient = testNew($sContext, $sName, $sClass
                        , $aaParams, $hProperties);

  return $oClient;
}

#--------------------------------------------------------------------

sub testNotification {
  my ($sName, $oClient) = @_;
  my $sTest="$sName: testNotification";
  my $sSubtest;

  my $sPath = "a/b/c/foo.txt";
  my @aActionParams= map { "arg$_" } (0..3);
  my @aDefault;
  my @aGroup;
  my $iAdd;

  my $crAdd = sub {
    $iAdd++;
    is_deeply(\@_
      , [ $sPath, $SVN::Wc::Notify::Action::add, @aActionParams ]
      ,"$sSubtest: schedule add - verifying parameters" );
  };
  my $crDelete = sub {
    is_deeply(\@_
      , [ $sPath, $SVN::Wc::Notify::Action::delete, @aActionParams ]
      ,"$sSubtest: schedule delete - verifying parameters" );
  };
  my $crGroup = sub {

    # omit action from test since it could be anything
    # instead test after by caller who knows what was passed

    push @aGroup, $_[1];
    is_deeply([@_[0,2..$#_]], [ $sPath, @aActionParams ]
      ,"$sSubtest: group - verifying parameters" );
  };
  my $crDefault = sub {

    # omit key, action from test since it could be anything
    # instead test after by caller who knows what was passed

    push @aDefault, [@_[0,2]];
    is_deeply([@_[1,3..$#_]], [ $sPath, @aActionParams ]
      , "$sSubtest: default: verifying parameters");
  };

  #---------------------------------------
  # check defaulting mechanism
  #---------------------------------------

  my ($hNotify, $crNotify) = @_;
  my @aForGroup
    =($SVN::Wc::Notify::Action::commit_added
      , $SVN::Wc::Notify::Action::commit_modified
      , $SVN::Wc::Notify::Action::commit_deleted
      , $SVN::Wc::Notify::Action::commit_replaced
      , $SVN::Wc::Notify::Action::commit_postfix_txdelta
     );
  my @aTestActions
    = ($SVN::Wc::Notify::Action::add
       , $SVN::Wc::Notify::Action::copy
       , $SVN::Wc::Notify::Action::delete
       , @aForGroup
       , $SVN::Wc::Notify::Action::resolved
      );

  $sSubtest="$sTest:handlingOfUndefAndHash";
  @aDefault=();
  @aGroup=();
  $iAdd=0;

  $hNotify = { default => $crDefault
             , commit => $crGroup
             , schedule =>
               {$SVN::Wc::Notify::Action::add => $crAdd
                , $SVN::Wc::Notify::Action::delete => undef
               }
             , resolved => undef
             };
  $crNotify = $oClient->configureNotification($hNotify);
  $crNotify->($sPath, $_, @aActionParams) for (@aTestActions);
  is($iAdd, 1, "$sSubtest - verifying per action call");
  is_deeply(\@aGroup, \@aForGroup
     , "$sSubtest - verifying group calls");
  is_deeply(\@aDefault
     , [['schedule', $SVN::Wc::Notify::Action::copy]
        , ['schedule', $SVN::Wc::Notify::Action::delete]
        , ['resolved',$SVN::Wc::Notify::Action::resolved]]
     , "$sSubtest - verifying default calls");

  #---------------------------------------
  # check keys
  #---------------------------------------

  my @aScheduleTests
    = ( $SVN::Wc::Notify::Action::add
        , $SVN::Wc::Notify::Action::delete
        , $SVN::Wc::Notify::Action::copy );
  my @aRevertTests
    = ( $SVN::Wc::Notify::Action::restore
        , $SVN::Wc::Notify::Action::revert
        , $SVN::Wc::Notify::Action::failed_revert);
  my @aResolvedTests
    = ( $SVN::Wc::Notify::Action::resolved );
  my @aUpdateTests
    = ( $SVN::Wc::Notify::Action::skip
       , $SVN::Wc::Notify::Action::update_add
       , $SVN::Wc::Notify::Action::update_delete
       , $SVN::Wc::Notify::Action::update_update
       , $SVN::Wc::Notify::Action::update_external
       , $SVN::Wc::Notify::Action::update_completed );
  my @aFollowTests
    = ( $SVN::Wc::Notify::Action::status_external
        , $SVN::Wc::Notify::Action::status_completed );
  my @aCommitTests
    = ( $SVN::Wc::Notify::Action::commit_added
        , $SVN::Wc::Notify::Action::commit_deleted
        , $SVN::Wc::Notify::Action::commit_modified
        , $SVN::Wc::Notify::Action::commit_replaced
        , $SVN::Wc::Notify::Action::commit_postfix_txdelta);
  my @aRevpropTests;
  my @aLockTests
    = ( $SVN::Wc::Notify::Action::locked
        , $SVN::Wc::Notify::Action::unlocked
        , $SVN::Wc::Notify::Action::failed_lock
        , $SVN::Wc::Notify::Action::failed_unlock );
  my @aMergeTests;
  my @aPatchTests;
  my @aBlameTests
    = ( $SVN::Wc::Notify::Action::blame_revision );

  if (1 <= $SVN::Core::VER_MAJOR) {
    if (5 <= $SVN::Core::VER_MINOR) {
      push @aScheduleTests
        , $SVN::Wc::Notify::Action::exists
        , $SVN::Wc::Notify::Action::changelist_set
        , $SVN::Wc::Notify::Action::changelist_clear
        , $SVN::Wc::Notify::Action::changelist_moved;
      push @aMergeTests
        , $SVN::Wc::Notify::Action::merge_begin
        , $SVN::Wc::Notify::Action::foreign_merge_begin;
      push @aUpdateTests
        , $SVN::Wc::Notify::Action::update_replace;

    }

    if (6 <= $SVN::Core::VER_MINOR) {
      push @aScheduleTests
        , $SVN::Wc::Notify::Action::property_added
        , $SVN::Wc::Notify::Action::property_modified
        , $SVN::Wc::Notify::Action::property_deleted
        , $SVN::Wc::Notify::Action::property_deleted_nonexistant;
      push @aRevpropTests
        , $SVN::Wc::Notify::Action::revprop_set
        , $SVN::Wc::Notify::Action::revprop_deleted;
      push @aUpdateTests
        , $SVN::Wc::Notify::Action::tree_conflict;
      push @aMergeTests
        , $SVN::Wc::Notify::Action::merge_completed;
      push @aFollowTests
        , $SVN::Wc::Notify::Action::failed_external;
    }
    if (7 <= $SVN::Core::VER_MINOR) {
      push @aUpdateTests
        , $SVN::Wc::Notify::Action::update_started
        , $SVN::Wc::Notify::Action::update_obstruction
        , $SVN::Wc::Notify::Action::update_external_removed
        , $SVN::Wc::Notify::Action::update_add_deleted
        , $SVN::Wc::Notify::Action::update_update_deleted
        , $SVN::Wc::Notify::Action::upgraded_path;
      push @aMergeTests
        , $SVN::Wc::Notify::Action::merge_record_info
        , $SVN::Wc::Notify::Action::merge_record_info_begin
        , $SVN::Wc::Notify::Action::merge_elide_info;
      push @aPatchTests
        , $SVN::Wc::Notify::Action::patch
        , $SVN::Wc::Notify::Action::patch_applied_hunk
        , $SVN::Wc::Notify::Action::patch_rejected_hunk
        , $SVN::Wc::Notify::Action::patch_hunk_already_applied;
      push @aFollowTests
        , $SVN::Wc::Notify::Action::url_redirect;

    }
  }

  @aTestActions=(@aScheduleTests, @aRevertTests, @aResolvedTests
                 , @aUpdateTests, @aFollowTests, @aCommitTests
                 , @aRevpropTests, @aLockTests, @aMergeTests
                 , @aPatchTests, @aBlameTests);

  $sSubtest = "$sTest: routing";
  $hNotify = { default => $crDefault };
  @aDefault=();

  my @aSchedule;
  $hNotify->{schedule} = sub { push @aSchedule, $_[1] };
  my @aRevert;
  $hNotify->{revert} = sub { push @aRevert, $_[1] };
  my @aResolved;
  $hNotify->{resolved} = sub { push @aResolved, $_[1] };
  my @aLog;
  $hNotify->{log} = sub { push @aLog, $_[1] };
  my @aUpdate;
  $hNotify->{update} = sub { push @aUpdate, $_[1] };
  my @aFollow;
  $hNotify->{follow} = sub { push @aFollow, $_[1] };
  my @aCommit;
  $hNotify->{commit} = sub { push @aCommit, $_[1] };
  my @aBlame;
  $hNotify->{blame} = sub { push @aBlame, $_[1] };
  my @aLock;
  $hNotify->{lock} = sub { push @aLock, $_[1] };
  my @aMerge;
  $hNotify->{merge} = sub { push @aMerge, $_[1] };
  my @aRevprop;
  $hNotify->{revprop} = sub { push @aRevprop, $_[1] };
  my @aPatch;
  $hNotify->{patch} = sub { push @aPatch, $_[1] };


  $crNotify = $oClient->configureNotification($hNotify);
  $crNotify->($sPath, $_, @aActionParams) for (@aTestActions);
  is_deeply(\@aSchedule, \@aScheduleTests, "$sSubtest: schedule");
  is_deeply(\@aRevert, \@aRevertTests, "$sSubtest: revert");
  is_deeply(\@aResolved, \@aResolvedTests, "$sSubtest: resolved");
  is_deeply(\@aUpdate, \@aUpdateTests, "$sSubtest: update");
  is_deeply(\@aFollow, \@aFollowTests, "$sSubtest: follow");
  is_deeply(\@aCommit, \@aCommitTests, "$sSubtest: commit");
  is_deeply(\@aRevprop, \@aRevpropTests, "$sSubtest: revprop");
  is_deeply(\@aLock, \@aLockTests, "$sSubtest: lock");
  is_deeply(\@aMerge, \@aMergeTests, "$sSubtest: merge");
  is_deeply(\@aPatch, \@aPatchTests, "$sSubtest: patch");
  is_deeply(\@aBlame, \@aBlameTests, "$sSubtest: blame");

  is_deeply(\@aDefault, [], "$sSubtest - verifying default calls")
    or diag("got=(@{[map { qq{(@$_)} } @aDefault]})");
}

#--------------------------------------------------------------------

sub testWc {
  my ($sName, $oClient, $bNotify) = @_;

  my $oSandbox = $SANDBOX->makeChild();

  my @aRepos = map {
    my $sRepo = $oSandbox->getFullPathName("repo$_");
    $REPO_CLASS->create($sRepo);
  } @VERSION_SUFFIXES[0..$WC_LAST_IDX];

  my @aRepoURLs = map {
    URI::file->new($_->getRoot())->canonical()->as_string();
  } @aRepos;

  my @aMirrors = map {
    my $sSuffix = $VERSION_SUFFIXES[$_];
    my $sRepo = $oSandbox->getFullPathName("mirror$sSuffix");
    $REPO_CLASS->create($sRepo, undef, undef, $aRepos[$_]->getUUID());
  } (0..$WC_LAST_IDX);

  my @aMirrorURLs = map {
    URI::file->new($_->getRoot())->canonical()->as_string();
  } @aMirrors;


  my @aWc = map { $oSandbox->makeChild("wc$_")
                } @VERSION_SUFFIXES[0..$WC_LAST_IDX];
  my @aWcRoots = map { $_->getRoot() } @aWc;

  my $iRev=0;

  # -----------
  # operate on working copy root
  # ------------

  $iRev = testWc_EmptyRoots($sName, $oClient, \@aWc, \@aWcRoots
     , \@aRepos, \@aRepoURLs, \@aMirrorURLs);

  # DEBUG - BEGIN
  #$iRev = testWc_Branching($sName, $oClient, \@aRepos, $iRev
  #   , \@aWc, 'trunk', 'branch1');
  #exit(1); #STOP_TESTING
  # DEBUG - END

  # ---------------------------------
  # remote repository operations
  # ---------------------------------

  $iRev = testWc_RepoPathOps($sName, $oClient, \@aRepoURLs, $iRev
       , 'testRemoteOps');

  # ---------------------------------
  # operate on a file inside the working copy
  # ---------------------------------

  $iRev = testWc_PathOps($sName, $oClient, \@aWc, $iRev, 1
     , [ 'A.txt', 'Hello,World!' ], 'B_txt', \@aRepoURLs);

  # ---------------------------------
  # operate on a directory inside the working copy
  # ---------------------------------

  $iRev = testWc_PathOps($sName, $oClient, \@aWc, $iRev, 0
     , 'A', 'B', \@aRepoURLs);

  # ---------------------------------
  # branch and merge
  # ---------------------------------

  $iRev = testWc_Branching($sName, $oClient, \@aRepos, $iRev
     , \@aWc, 'trunk', 'branch1');

  # ---------------------------------
  # set and clear revision properties
  # ---------------------------------

  $iRev = testWc_Revprops($sName, $oClient, \@aRepoURLs, $iRev, 0);
  $_->enableRevProps() for @aRepos;
  $iRev = testWc_Revprops($sName, $oClient, \@aRepoURLs, $iRev, 1);

  # ---------------------------------
  # test directory listing
  # ---------------------------------

  my @aListing=qw(X.txt Y.txt Z.txt B1/ B1/XX.txt);
  $iRev = testWc_Listing($sName, $oClient, \@aWc, $iRev
      , 'A1', \@aListing);

  # ---------------------------------
  # test edit history
  # ---------------------------------

  $iRev = testWc_EditHistory($sName, $oClient, \@aWc, $iRev
    , 'EditTest.txt');


  # ---------------------------------
  # test edit history
  # ---------------------------------

  $iRev = testWc_ImportExport($sName, $oClient, \@aRepoURLs, $iRev
    , 'import1', \@aWc, $oSandbox->makeChild('exportTest'));

  diag("\nTesting of <$sName> complete\n");
  return;
}

#--------------------------------------------------------------------

sub testWc_Branching {
  my ($sName, $oClient, $aRepos, $iRev, $aWc, $sTrunk, $sBranch) = @_;

  my $aTrunk  = okMkdir($sName, $oClient, $aWc, $sTrunk, []
     => $ADD_STATUS, $ADD_ACTIONS);
  okCommit($sName, $oClient, $aTrunk, []
     => $NORMAL_STATUS, ++$iRev, $ADD_DIR_COMMIT_ACTIONS);

  my $aBranch = okMkdir($sName, $oClient, $aWc, $sBranch,[]
     => $ADD_STATUS, $ADD_ACTIONS);
  okCommit($sName, $oClient, $aBranch, []
     => $NORMAL_STATUS, ++$iRev, $ADD_DIR_COMMIT_ACTIONS);

  #-------------------------
  # Switch directory to a branch
  #-------------------------

  # make the directory that stores trunk hold fils from branch
  # i.e. even though we are editing locally $aTrank, the commits are
  # going to $sBranch in the repository

  okSwitch($sName, $oClient, $aTrunk, [$aRepos], $sBranch, []
     => [ $SVN::Wc::Notify::Action::update_update, @$UPDATE_ACTIONS]);

  my $aSounds = okAdd($sName, $oClient, $aWc
     , [ "$sTrunk/Cow.sound", "Moooo\n" ], []
     => $ADD_STATUS, $ADD_ACTIONS);
  okCommit($sName, $oClient, $aTrunk, []
     => $NORMAL_STATUS, ++$iRev, $ADD_FILE_COMMIT_ACTIONS);

  #-------------------------
  # Modify the file, then revert
  #-------------------------

  # add something to the end of the file so that diff with report
  # something other than ''

  $SANDBOX->appendToFile($_,"Brrrr") for @$aSounds;

  okDiff($sName, $oClient, [$aSounds], undef, []
    => "Moooo\n+Brrrr", '');

  okRevert($sName, $oClient, $aSounds,[] => $NORMAL_STATUS, 1);

  okDiff($sName, $oClient, [$aSounds], undef, []
    => '', '');

  # due to revert, no changes
  okCommit($sName, $oClient, $aBranch, []
     => $NORMAL_STATUS, undef, []);

  #-------------------------
  # Switch directory back to trunk
  #-------------------------

  # Now switch $aTrunk back to $sTrunk
  # we have a delete action because the branch has a file that is
  # not in the trunk

  okSwitch($sName, $oClient, $aTrunk, [$aRepos], $sTrunk, []
     => [ $SVN::Wc::Notify::Action::update_delete, @$UPDATE_ACTIONS]);

  okAdd($sName, $oClient, $aWc, ["$sBranch/Cat.sound", "Meow\n"], []
     => $ADD_STATUS, $ADD_ACTIONS);
  okCommit($sName, $oClient, $aBranch, []
     => $NORMAL_STATUS, ++$iRev, $ADD_FILE_COMMIT_ACTIONS);

  # Merge should result in 2 files in the directory
  my $aExpectedActions = isBeforeOrAtRelease(1,4)
    ? [  ($SVN::Wc::Notify::Action::update_add) x 2
         , @$MERGE_ACTIONS
      ]
    : [ $SVN::Wc::Notify::Action::merge_begin
        , ($SVN::Wc::Notify::Action::update_add) x 2
        , @$MERGE_ACTIONS
      ];

  okMerge($sName, $oClient, [ $aTrunk ], [ $aBranch ], $aTrunk,[]
     => [qw(Cow.sound Cat.sound)], $aExpectedActions);
  return $iRev;
}

#--------------------------------------------------------------------

sub testWc_EditHistory {
  my ($sName, $oClient, $aWcs, $iRev, $sRelPath) = @_;
  my $sFirstEdit="First edit\n";
  my $sSecondEdit="Second edit\n";
  my @aFullPaths;

  #--------------------------------
  # first edit
  #--------------------------------

  foreach my $oWcs (@$aWcs) {
    my $sFullPath = $oWcs->addFile($sRelPath, $sFirstEdit);
    $oClient->add($sFullPath);
    $oClient->commit($sFullPath);
    push @aFullPaths, $sFullPath;
  }
  $iRev++;  # for commit in loop above

  my $sContent = $sFirstEdit;
  my $hExpectedInfo
    = { last_changed_rev => $iRev
        , kind => $SVN::Node::file
        , lock => 0
      };

  my $sSubtest="$sName:firstEdit";
  my $hProps = {};
  okCat($sSubtest, $oClient, [\@aFullPaths], []  =>  $sContent);
  okBlame($sSubtest, $oClient, [\@aFullPaths],[] => 1, $sContent);

  # get props from both working copy and repository version
  okPropget($sSubtest, $oClient, [\@aFullPaths], []
     => $iRev, $hProps);
  okPropget($sSubtest, $oClient, [\@aFullPaths, 'HEAD'], []
     => $iRev, $hProps);

  okProplist($sSubtest, $oClient, [\@aFullPaths], [] => undef);
  okProplist($sSubtest, $oClient, [\@aFullPaths, 'HEAD'],[] => undef);


  okInfo($sSubtest, $oClient, [\@aFullPaths], []
     => 1, $hExpectedInfo);

  # run with both the $bChangedPaths flag set to true and false
  okLog($sSubtest, $oClient, [\@aFullPaths ], []
     => 1, [('') x 1]);
  okLog($sSubtest, $oClient, [\@aFullPaths ], [undef,undef,1]
     => 1, [('') x 1]);

  #--------------------------------
  # second edit
  #--------------------------------

  foreach my $i (0..$#$aWcs) {
    my $oWcs = $aWcs->[$i];
    my $sFullPath = $aFullPaths[$i];
    $oWcs->appendToFile($sRelPath, $sSecondEdit);
    $oClient->propset($sFullPath, 'X', 'lalala');
    $oClient->propset($sFullPath, 'Y', 'yayaya');
    $oClient->commit($sFullPath);
  }
  $iRev++;  # for commit in loop above

  $sSubtest="$sName:secondEdit";
  $sContent .= $sSecondEdit;
  $hExpectedInfo->{last_changed_rev} = $iRev;
  $hProps = { X => 'lalala', Y => 'yayaya' };

  okCat($sSubtest, $oClient, [\@aFullPaths], []  =>  $sContent);
  okBlame($sSubtest, $oClient, [\@aFullPaths],[] => 2, $sContent);

  # get props from both working copy and repository version
  okPropget($sSubtest, $oClient, [\@aFullPaths], []
     => $iRev, $hProps);
  okPropget($sSubtest, $oClient, [\@aFullPaths, 'HEAD'], []
     => $iRev, $hProps);

  okProplist($sSubtest, $oClient, [\@aFullPaths], [] => $hProps);
  okProplist($sSubtest, $oClient, [\@aFullPaths,'HEAD'],[]=> $hProps);

  # info has 1 visit because it is per-path
  okInfo($sSubtest, $oClient, [\@aFullPaths], []
    => 1, $hExpectedInfo);

  # log  has 2 bacuase it is per revision
  okLog($sSubtest, $oClient, [\@aFullPaths], [undef,undef,1]
    => 2, [('') x 2]);

  return $iRev;
}

#--------------------------------------------------------------------

sub testWc_EmptyRoots {
  my ($sName, $oClient, $aWcs, $aWcRoots, $aRepos, $aRepoURLs
      , $aMirrorURLs) = @_;
  my $iRev = 0;

  okCheckout($sName, $oClient, [ $aRepoURLs ], $aWcRoots, []
    => $aRepos, 0, $iRev);

  for my $i (0..$#$aWcs) {
    my $sWc = $aWcRoots->[$i];
    my $sRepoURL = $aRepoURLs->[$i];
    my $sTest = "$sName: getRepositoryRootURL($sWc)";

    is($oClient->getRepositoryRootURL($sWc), $sRepoURL
       , "$sTest - verifying repository root");
  }

  okRelocate($sName, $oClient, $aWcs, $aMirrorURLs, []);
  okRelocate($sName, $oClient, $aWcs, $aRepoURLs, []);

  okStatus($sName, $oClient, [ $aWcRoots ], []
    => $NORMAL_STATUS,[],[]);
  okUpdate($sName, $oClient, [ $aWcRoots ], [] => 0);
  okResolved($sName, $oClient, $aWcRoots, [] => []);
  okCommit($sName, $oClient, $aWcRoots, []
    => $NORMAL_STATUS, undef, []);

  okCleanup($sName, $oClient, $aWcRoots);
  return $iRev;
}

#--------------------------------------------------------------------

sub testWc_ImportExport {
  my ($sName, $oClient, $aRepoURIs, $iRev, $sBranch, $aWcs
      , $oSandbox) = @_;

  #--------------------------
  # Import
  #--------------------------

  my $aBranches = okImport($sName, $oClient,  $IMPORT_DIR, $aRepoURIs
      , $sBranch, []
      =>  ++$iRev, $IMPORT_LISTING);
  okList($sName, $oClient, [ $aBranches ], [], $IMPORT_LISTING);

  #--------------------------
  # Export from repository
  #--------------------------

  # can't export to an existing directory, so create a directory
  # immediately under the sandbox root

  my @aExport = map { $oSandbox->getFullPathName("Head$_")
                    } @VERSION_SUFFIXES[0..$WC_LAST_IDX];
  okExport($sName, $oClient, [ $aBranches, 'HEAD' ], \@aExport, []
      => $IMPORT_LISTING);

  #--------------------------
  # Export from working copy
  #--------------------------

  my @aWcBranches;
  foreach my $i (0..$#$aRepoURIs) {
    my $sSource = $aBranches->[$i];
    my $oWc = $aWcs->[$i];
    my $sPath = $oWc->getFullPathName($sBranch);
    $oClient->checkout($sSource, undef, $sPath);

    #local $"="\n";
    #print STDERR "\ndirectory exists? ", ((-d $sPath) ? 1 : 0)
    #  , "\nworking dir contents=@{$oWc->list(undef,1)}\n";

    push @aWcBranches, $sPath;
  }

  @aExport = map { $oSandbox->getFullPathName("Working$_")
                 } @VERSION_SUFFIXES[0..$WC_LAST_IDX];
  okExport($sName, $oClient, [ \@aWcBranches ], \@aExport, []
      => $IMPORT_LISTING);

  return $iRev;
}


#--------------------------------------------------------------------

sub testWc_Listing {
  my ($sName, $oClient, $aWcs, $iRev, $sDir, $aRelPaths
      , $aListing)=@_;
  $aListing = [ map { /^(.+)\/$/ ? $1 : $_ } @$aRelPaths ]
    unless defined($aListing);

  # populate the working copies
  my @aListPaths;
  my @ahFullPaths;
  foreach my $oWcs (@$aWcs) {
    my $sListPath = $oWcs->getFullPathName($sDir);
    $oClient->mkdir($sListPath);

    my $hFullPaths = $oWcs->addPaths($sDir, $aRelPaths);
    $oClient->add($hFullPaths->{$_},0) foreach (@$aRelPaths);
    $oClient->commit($oWcs->getRoot());

    push @ahFullPaths, $hFullPaths;
    push @aListPaths, $sListPath;
  }

  okList($sName, $oClient, [\@aListPaths], [], $aListing);
  foreach my $i (0..$#$aWcs) {
    # reverse sort to make sure we delete deepest paths first
    $oClient->delete(reverse sort [values %{$ahFullPaths[$i]}]);
    $oClient->commit($aListPaths[$i]);
  }

  okList($sName, $oClient, [\@aListPaths], [], []);
  return $iRev + 2;
}

#--------------------------------------------------------------------

sub testWc_PathOps {
  my ($sName, $oClient, $aWc, $iRev, $bFile, $xAdd, $sRelPath
      , $aRepoURLs) = @_;
  my $sCopyRelPath  = "${sRelPath}_copy1";
  my $sCopyRelPath2 = "${sRelPath}_copy2";
  my $sMoveRelPath  = "${sRelPath}_move1";
  my $sMoveRelPath2 = "${sRelPath}_move2";
  my $aExpectedActions;

  # add a path (file or dir)

  my $aPaths;
  if ($bFile) {

    #-----------------------------------
    # test add with files
    #-----------------------------------

    $aPaths = okAdd($sName, $oClient, $aWc, $xAdd, []
        => $ADD_STATUS, $ADD_ACTIONS);

    # reverts unschedules the add, but does not delete the file
    okRevert($sName, $oClient, $aPaths, []
        => $UNVERSIONED_STATUS, 1);

    okAdd("$sName-after revert", $oClient, $aPaths, undef, []
        => $ADD_STATUS, $ADD_ACTIONS);

    okCommit($sName, $oClient, $aPaths, []
        => $NORMAL_STATUS, ++$iRev, $ADD_FILE_COMMIT_ACTIONS);

    #-----------------------------------
    # test lock, unlock
    #-----------------------------------

    okLock($sName, $oClient, $aPaths, ['---']
        => $LOCK_FILE_ACTIONS);
    okUnlock($sName, $oClient, $aPaths, []
        => $UNLOCK_FILE_ACTIONS);

  } else {

    #-----------------------------------
    # test mkdir, add with directories
    #-----------------------------------

    $aPaths = okMkdir($sName, $oClient, $aWc, $xAdd, []
        => $ADD_STATUS, $ADD_ACTIONS);

    # reverts unschedules the add, but does not delete the directory
    okRevert("$sName-after mkdir", $oClient, $aPaths, []
        => $UNVERSIONED_STATUS, 1);

    # mkdir fails because directory already exists, but add will work
    okMkdir("$sName-after mkdir+revert", $oClient, $aPaths, undef, []
        => $UNVERSIONED_STATUS, $SOME_STRING_EXCEPTION);

    okAdd("$sName-after mkdir+revert", $oClient, $aPaths, undef, []
        => $ADD_STATUS, $ADD_ACTIONS);

    # mkdir within a scheduled to be added directory is ok

    my $aLocalX1 = okMkdir($sName, $oClient, $aWc, "$xAdd/X1", []
       => $ADD_STATUS, $ADD_ACTIONS);

    okCommit("$sName - after mkdir+revert+mkdir"
       , $oClient, $aPaths, []
        => $NORMAL_STATUS, ++$iRev, [(@$ADD_DIR_COMMIT_ACTIONS) x 2]);

    #-----------------------------------
    # test obstructing directory
    #-----------------------------------

    # create a directory in the repository that isn't yet in the
    # working copy

    my @aRemoteX2 = map {
      _appendRelPathToURL($oClient->getRepositoryURL($_), 'X2');
    } @$aPaths;
    okMkdir($sName, $oClient, \@aRemoteX2, undef, []);
    $iRev++;  #remote copy auto commits

    # add an obstructing directory

    okAdd($sName, $oClient, $aWc, ["$xAdd/X2"],[]
        => $ADD_STATUS, $ADD_ACTIONS);
    okUpdate("$sName - obstructed", $oClient, $aPaths, []
        => $iRev, $SOME_STRING_EXCEPTION);
    okCommit("$sName - obstructed", $oClient, $aPaths, []
        => $NORMAL_STATUS, undef, $SOME_STRING_EXCEPTION);

    # add a non-obstructing file so that we have something
    # to test commit behavior with after we clean up the obstruction

    okAdd($sName, $oClient, $aWc, ["$xAdd/X2.txt"],[]
       => $ADD_STATUS, $ADD_ACTIONS);

    # to fix the problem it isn't enough to delete the file
    # we also need to unschedule the add

    for my $oWc (@$aWc) { $oWc->removePath("$xAdd/X2") }
    okUpdate("$sName - obstructing file removed"
       , $oClient, $aPaths, []
        => $iRev, $SOME_STRING_EXCEPTION);
    okCommit("$sName - obstructing file removed"
       , $oClient, $aPaths, []
        => $NORMAL_STATUS, undef, $SOME_STRING_EXCEPTION);

    # unschedule the add and all is well
    for my $oWc (@$aWc) {
      $oClient->revert($oWc->getFullPathName("$xAdd/X2"));
    }
    okUpdate("$sName - obstructing file unscheduled"
        , $oClient, [ $aPaths ], [] => $iRev
             , [ $SVN::Wc::Notify::Action::update_add
                 , $SVN::Wc::Notify::Action::update_update
                 , @$UPDATE_ACTIONS ]);
    okCommit("$sName - obstructing file unscheduled"
        , $oClient, $aPaths, []
        => $NORMAL_STATUS, ++$iRev, $ADD_FILE_COMMIT_ACTIONS);
  }

  #-----------------------------------
  # verify root URL for non-root path
  #-----------------------------------

  {
    my $sPath = $aPaths->[0];
    my $sRepoURL = $aRepoURLs->[0];
    is($oClient->getRepositoryRootURL($sPath), $sRepoURL
       , "getRepositoryRootURL: verifying repository root "
       ."for $sPath");
  }

  #-----------------------------------
  # test wc copy
  #-----------------------------------

  my $aCopies = okCopy($sName, $oClient, [$aPaths], $aWc
     , [$sCopyRelPath, $bFile],[]);

  my $aUpdateActions= $bFile
    ? $UPDATE_ACTIONS
    : [ $SVN::Wc::Notify::Action::update_update, @$UPDATE_ACTIONS ];
  my $aCommitActions = $bFile
    ? $COPY_COMMIT_ACTIONS
    : [ ($SVN::Wc::Notify::Action::commit_added) x 3
       , @$COPY_COMMIT_ACTIONS];

  my @aRoots = map { $_->getRoot() } @$aWc;

  # Changes from 1.4 to 1.5
  # * 1.5 allows copies of copies (it just adds them), 1.4 does not
  # * 1.5 adds a svn:mergeinfo property on the copied file, 1.4 does not
  # * 1.5 on copy has one add for each dir and parent (like update)
  #   rather than one add for each path added, as in 1.4

  if (isBeforeOrAtRelease(1,4)) {

    # copies of uncommitted adds are not allowed
    okCopy("$sName - copy uncommitted add", $oClient, [$aCopies]
      , $aWc, [ $sCopyRelPath2,$bFile ], [] => $SOME_STRING_EXCEPTION);

    # the failed copy leaves the working copy in an inconsistent state
    # we can't commit without cleanup

    okUpdate("$sName - failed copy w/o cleanup", $oClient, [\@aRoots], []
       => $iRev, $SOME_STRING_EXCEPTION);
    okCommit("$sName - failed copy w/o cleanup", $oClient, $aCopies, []
       => $NORMAL_STATUS, undef, $SOME_STRING_EXCEPTION);

    # after cleanup all is well
    # Note: commit works before update too
    okCleanup("$sName - after failed copy", $oClient, \@aRoots);

    # one update_update for each changed directory and for each
    # of its parents

    $aExpectedActions = $aUpdateActions;
    okUpdate("$sName - update - failed copy w/ cleanup"
       , $oClient,[\@aRoots], []  => $iRev, $aExpectedActions);

    # Note: one add for the copied dir and each of its members
    # (X1/ X2/ X2.txt)

    $aExpectedActions =  $bFile
      ? $COPY_COMMIT_ACTIONS
      : [ ($SVN::Wc::Notify::Action::commit_added) x 3
          , @$COPY_COMMIT_ACTIONS];
    okCommit("$sName - commit - failed copy w/ cleanup", $oClient, $aCopies, []
       => $NORMAL_COPY_STATUS, ++$iRev, $aExpectedActions);

  } else {

    # one update_update for each changed directory and for each
    # of its parents

    $aExpectedActions = $aUpdateActions;
    okUpdate("$sName - update after copy"
       , $oClient,[\@aRoots], []  => $iRev, $aExpectedActions);

    # Note: one add for dir and parent, like update

    $aExpectedActions =  $bFile
      ? $COPY_COMMIT_ACTIONS
      : [ $SVN::Wc::Notify::Action::commit_added, @$COPY_COMMIT_ACTIONS];

    okCommit("$sName - commit after copy", $oClient, $aCopies, []
       => $NORMAL_COPY_STATUS, ++$iRev, $aExpectedActions);

    my $hProperties = $oClient->getPathProperties($aCopies->[0]);
    #printf STDERR "path=%s: props=%s\n", $aCopies->[0]
    #   , "@{[map { $_.'='.$hProperties->{$_} } keys %$hProperties ]}";
  }

  #-----------------------------------
  # test wc move
  #-----------------------------------

  # one add for the moved dir and a delete for each member of the
  # moved directory (. X1/ X2/ X2.txt)
  $aExpectedActions = $bFile
    ? $MOVE_ACTIONS
    : [ $SVN::Wc::Notify::Action::add
        , ($SVN::Wc::Notify::Action::delete) x 4
      ];

  my $aMoved = okMove($sName, $oClient, $aCopies, $aWc
     , [$sMoveRelPath,$bFile], []
     , => $aExpectedActions);

  my $aCommit = [ map { [$aCopies->[$_], $aMoved->[$_]]
                      } (0..$#$aCopies) ];


  # changes from subversion 1.4 to 1.5
  # - moves of uncommitted adds are allowed

  if (isBeforeOrAtRelease(1,4)) {

    okMove("$sName - move uncommitted move", $oClient, $aMoved
           , $aWc, [ $sMoveRelPath2, $bFile ], []
           => $SOME_STRING_EXCEPTION);

    okUpdate("$sName - failed move w/o cleanup"
             , $oClient, \@aRoots, []
             => $iRev, $SOME_STRING_EXCEPTION);
    okCommit("$sName - failed move w/o cleanup"
             , $oClient, $aCommit, []
             => $NORMAL_COPY_STATUS, undef, $SOME_STRING_EXCEPTION);

    # cleanup and all is well
    # Note1: commit works after update too

    okCleanup("$sName - after failed copy", $oClient, \@aRoots);
    okCommit("$sName - failed move w/ cleanup", $oClient, $aCommit, []
             => [$NOT_FOUND_STATUS, $NORMAL_COPY_STATUS], ++$iRev
             , $MOVE_COMMIT_ACTIONS);
    okUpdate("$sName - failed move w/ cleanup", $oClient,[\@aRoots], []
             => $iRev, $UPDATE_ACTIONS);
  } else {

    okCommit("$sName - commit: move", $oClient, $aCommit, []
             => [$NOT_FOUND_STATUS, $NORMAL_COPY_STATUS], ++$iRev
             , $MOVE_COMMIT_ACTIONS);
    okUpdate("$sName - update: move", $oClient,[\@aRoots], []
             => $iRev, $UPDATE_ACTIONS);
  }


  #-----------------------------------
  # test properties: add, set, delete
  #-----------------------------------

  # 1.5 adds the svn:mergeinfo property to copy/moved paths
  my $hRemaining = isBeforeOrAtRelease(1,4)
    ? {} : { 'svn:mergeinfo' => '' };

  my $hProps ={a=>10,b=>20};
  my $aRevertActions = $bFile
     ? $REVERT_ACTIONS
     : [ (@$REVERT_ACTIONS) x 4 ];  # for (. X1/ X2/ X2.txt )
  $aCommitActions = $bFile
     ? $MOD_COMMIT_ACTIONS
     : [ (@$MOD_COMMIT_ACTIONS) x 4 ];  # for (. X1/ X2/ X2.txt )


  # add properties to a versioned path

  okPropset("$sName - add props", $oClient, $aMoved, $hProps, []
     => $MOD_PROP_STATUS);

  okRevert("$sName - revert add props", $oClient, $aMoved, []
     => $NORMAL_COPY_STATUS, 1, $aRevertActions);

  okPropset("$sName - redo add props", $oClient, $aMoved, $hProps, []
     => $MOD_PROP_STATUS);

  okCommit("$sName - commit add props", $oClient, $aMoved, []
     => $NORMAL_PROP_STATUS, ++$iRev, $aCommitActions);

  # modify properties

  $hProps->{a} = 111;

  okPropset("$sName - mod props", $oClient, $aMoved, $hProps, []
     => $MOD_PROP_STATUS);

  okRevert("$sName - revert mod props", $oClient, $aMoved, []
     => $NORMAL_PROP_STATUS, 1, $aRevertActions);

  okPropset("$sName - redo mod props", $oClient, $aMoved, $hProps, []
     => $MOD_PROP_STATUS);

  okCommit("$sName - commit mod props", $oClient, $aMoved, []
     => $NORMAL_PROP_STATUS, ++$iRev, $aCommitActions);

  # remove properties

  okPropdel("$sName - del props", $oClient, $aMoved
    , [ keys %$hProps ], []
     => $hRemaining, $MOD_PROP_STATUS);

  okRevert("$sName - revert del props", $oClient, $aMoved, []
     => $NORMAL_PROP_STATUS, 1, $aRevertActions);

  okPropdel("$sName - redo del props", $oClient, $aMoved
     , [ keys %$hProps ], []
     => $hRemaining, $MOD_PROP_STATUS);

  okCommit("$sName - commit del props", $oClient, $aMoved, []
     => $NORMAL_COPY_STATUS, ++$iRev, $aCommitActions);

  #-----------------------------------
  # test delete
  #-----------------------------------

  # delete the moved copy


  my $aDelActions = $bFile
     ? $DEL_ACTIONS
     : [ (@$DEL_ACTIONS) x 4 ];  # for (. X1/ X2/ X2.txt )

  okDelete("$sName - delete moved dir", $oClient, $aMoved, []
     => $DEL_STATUS, $aDelActions);

  okRevert("$sName - revert delete moved dir", $oClient, $aMoved, []
     => $NORMAL_COPY_STATUS, 1, $aRevertActions);

  okDelete("$sName - redo delete moved dir", $oClient, $aMoved, []
     => $DEL_STATUS, $aDelActions);

  # not clear why but even for a populated directory there is only
  # ONE delete action, not one for each (. X1/ X2/ X2.txt)

  okCommit("$sName - commit del moved dir", $oClient, $aMoved, []
     => $NOT_FOUND_STATUS, ++$iRev, $DEL_COMMIT_ACTIONS);

  return $iRev;
}

#--------------------------------------------------------------------

sub testWc_Revprops {
  my ($sName, $oClient, $aPaths, $iRev
      , $bEnabled, $hInitProps, $hProps) = @_;
  if (!defined($bEnabled)) {
    $bEnabled = 0;
  }
  if (!defined($hInitProps)) {
    $hInitProps = {};
  }
  if (!defined($hProps)) {
    $hProps = { a => "apple", b => "bananna" };
  }

  my ($hAll, $hRemaining, $aModActions);
  if ($bEnabled) {
    $hAll = { %$hInitProps, %$hProps };
    $hRemaining = { map { $_ => $hAll->{$_} } keys %$hInitProps };
  } else {
    $aModActions = $SOME_STRING_EXCEPTION;
    $hAll = $hInitProps;
    $hRemaining = $hInitProps;
  }

  okRevprop_set($sName, $oClient, [$aPaths,$iRev], $hProps, []
     => $iRev, $hAll, $aModActions);

  okRevprop_list($sName, $oClient, [$aPaths,$iRev],[]
     => $iRev, $hAll);

  okRevprop_get($sName, $oClient, [$aPaths,$iRev],[]
     => $iRev, $hAll);

  okRevprop_delete($sName, $oClient, [$aPaths,$iRev], $hProps, []
     => $iRev, $hRemaining, $aModActions);
  return $iRev;
}


#--------------------------------------------------------------------

sub testWc_RepoPathOps {
  my ($sName, $oClient, $aRepoURLs, $iRev, $sDir) = @_;

  my $sDirFrom = $sDir.'_from';
  my $sDirCopy = $sDir.'_copy';
  my $hProps   = { 'A' => 'apple', 'B' => 'bananna' };

  my @aFrom = map { _appendRelPathToURL($_, $sDirFrom) } @$aRepoURLs;
  okMkdir($sName, $oClient, \@aFrom, undef, []);
  $iRev++;

  my @aCopy = map { _appendRelPathToURL($_, $sDirCopy) } @$aRepoURLs;
  okCopy($sName, $oClient, [\@aFrom, 'HEAD'], \@aCopy, undef, []);
  $iRev++;

  # remote setting of paths is not supported until
  # $IDX_REMOTE_PROPSET

  if ($IDX_REMOTE_PROPSET <= $WC_LAST_IDX) {
    my $aPaths = _selectPaths(\@aCopy, $IDX_REMOTE_PROPSET);
    okPropset($sName, $oClient, \@aCopy, $hProps, []);
    $iRev++;

    okPropdel($sName, $oClient, \@aCopy, $hProps, []);
    $iRev++;
  }

  my @aDelete = map { [$aFrom[$_], $aCopy[$_] ] } (0..$#aFrom);
  okDelete($sName, $oClient, \@aDelete, []);
  $iRev++;

  return $iRev;
}

#==================================================================
# Miscellenous tools
#==================================================================

sub _makeCall($$) {
  my ($sName, $aArgs) = @_;
  return "$sName("
    . ($aArgs 
       ? join(',', map { defined($_) ? $_ :'undef';} @$aArgs) : '')
    . ')';
}

#==================================================================
# TEST PLAN
#==================================================================

testDefaults();
testClient_Local_NoAuth();

# skip version specific tests
SKIP: {
  skip("Tests targetted at subversion 1.4, testing ".
       $SVN::Core::VER_MAJOR.'.'.$SVN::Core::VER_MINOR, 112)
    unless isBeforeOrAtRelease(1,4);
}

if ($NAG_REPORT_SWIG_BUGS && keys %SWIG_BINDING_BUGS) {
  my $sMsg="SWIG binding bugs found: need to report";
  $sMsg .= "\n\t$_" for keys %SWIG_BINDING_BUGS;
  diag("\n\n$sMsg\n\n");
};
