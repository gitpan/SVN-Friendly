use strict;
use warnings;
use Test::More tests => 113;

use Exception::Lite;
Exception::Lite::onDie(3);

#------------------------------------------------------------------
BEGIN { use_ok('SVN::Friendly::Repos') or BAIL_OUT; };
my $TEST_CLASS = "SVN::Friendly::Repos";
use SVN::Friendly::Repos;

my $SWIG_VERSION = sprintf('%d.%03d.%03d%s'
                           , $SVN::Core::VER_MAJOR
                           , $SVN::Core::VER_MINOR
                           , $SVN::Core::VER_PATCH
                           , (defined($SVN::Core::VER_NUMTAG)
                              ? $SVN::Core::VER_NUMTAG : '')
                          );
my $SVN_REPO_FORMAT = '5';

my $UUID_REGEX
  = qr([0-9a-f]{8,8}(?:-[0-9a-f]{4,4}){3,3}-[0-9a-f]{12,12});

#------------------------------------------------------------------
use Test::New qw(testNew testNewSingleton);
use Test::Sandbox qw(makeSandbox);

#------------------------------------------------------------------
use File::Spec;
use File::Temp;

#==================================================================
# TEST SUITES
#==================================================================

sub testEmptyRepository {
  my $sContext  = 'testEmptyRepository';
  my $hProperties = {getSwigVersion => $SWIG_VERSION
                    , getYoungestRevision => '0'
                    , getHead => '0'
                    };

  # create FSFS repository
  $hProperties->{getFileSystemType} = 'fsfs';
  testRepository($sContext, 'FSFS'
                 , [[]
                    , [ undef]
                    , [ undef, undef]
                    , [ undef, $SVN::Fs::TYPE_FSFS ]
                   ]
                 , $hProperties);

  # create BDB repository
  $hProperties->{getFileSystemType} = 'bdb';
  testRepository($sContext, 'BDB'
                 , [[ undef, $SVN::Fs::TYPE_BDB ]]
                 , $hProperties);
}

#==================================================================
# GENERATE DATA/EXPECTATIONS
#==================================================================

#------------------------------------------------------------------
# Properties whose values

sub setReposRootPropertyExpectations {
  my ($hProperties, $sRoot) = @_;

  $hProperties->{'getRoot'} = $sRoot;
  $hProperties->{'getConfDir'}
    = File::Spec->rel2abs('conf', $sRoot);
  $hProperties->{'getDbDir'}
    = File::Spec->rel2abs('db', $sRoot);
  $hProperties->{'getDbLogLockFile'} = File::Spec
    ->rel2abs( File::Spec->catfile('locks', 'db-logs.lock'), $sRoot);
  $hProperties->{'getHookDir'}
    = File::Spec->rel2abs('hooks', $sRoot);
  $hProperties->{'getLockDir'}
    = File::Spec->rel2abs('locks', $sRoot);
  $hProperties->{'getSvnserveConfFile'} = File::Spec
    ->rel2abs(File::Spec->catfile('conf', 'svnserve.conf'), $sRoot);
}

#==================================================================
# SUBTESTS
#==================================================================

sub testRepository {
  my ($sContext, $sName, $aaCreateParams, $hProperties) = @_;
  my $sClass  = $TEST_CLASS;
  my $aCreate = [ $sClass, 'create' ];
  my ($sRoot, $aParams, $oCreateRepos, $oOpenRepos);

  # create the repository

  $sRoot  = makeSandbox($TEST_CLASS);
  setReposRootPropertyExpectations($hProperties, $sRoot);
  $aParams = $aaCreateParams->[0];

  $oCreateRepos = testNew($sContext, $sName, $aCreate
          , [[$sRoot, @$aParams]], $hProperties);

  # create it with different parameters

  foreach my $i (1..$#{$aaCreateParams}) {
    $sRoot = makeSandbox($TEST_CLASS);
    setReposRootPropertyExpectations($hProperties, $sRoot);

    $aParams = $aaCreateParams->[$i];
    $oCreateRepos = testNew($sContext, 'FSFS', $aCreate
            , [[ $sRoot, @$aParams ]], $hProperties);
  }

  # reopen the last created repository - do we get the same object?

  setReposRootPropertyExpectations($hProperties, $sRoot);
  $oOpenRepos = testNewSingleton($sContext, $sName, $sClass
      , [$sRoot], [[$oCreateRepos],[$oCreateRepos->getSvnRepos()]]
      , $hProperties);
  is($oOpenRepos, $oCreateRepos, "open repos == create repos");


  # check additional functionality

  like($oCreateRepos->getFormat(), qr{\d+}
       , "Repository format looks like an integer");

  # check UUID

  like($oCreateRepos->getUUID(), $UUID_REGEX
       , "$sName: getRepositoryUUID" );


  #-----------------------------------
  # Prerequisites:
  # - getHookDir - tested via $hProperties
  # ----------------
  # getHookFile

  my $sHookDir = $oCreateRepos->getHookDir();
  is($oCreateRepos->getHookFile($sClass->START_COMMIT)
     , File::Spec->rel2abs('start-commit',$sHookDir)
     , "start commit hook");
  is($oCreateRepos->getHookFile($sClass->PRE_COMMIT)
     , File::Spec->rel2abs('pre-commit',$sHookDir)
     , "pre-commit hook");
  is($oCreateRepos->getHookFile($sClass->PRE_LOCK)
     , File::Spec->rel2abs('pre-lock',$sHookDir)
     , "pre-lock hook");
  is($oCreateRepos->getHookFile($sClass->POST_LOCK)
     , File::Spec->rel2abs('post-lock',$sHookDir)
     , "post-lock hook");
  is($oCreateRepos->getHookFile($sClass->PRE_UNLOCK)
     , File::Spec->rel2abs('pre-unlock',$sHookDir)
     , "pre-unlock hook");
  is($oCreateRepos->getHookFile($sClass->POST_UNLOCK)
     , File::Spec->rel2abs('post-unlock',$sHookDir)
     , "post-unlock hook");
  is($oCreateRepos->getHookFile($sClass->PRE_REVPROP)
     , File::Spec->rel2abs('pre-revprop-change',$sHookDir)
     , "pre-revprop hook");
  is($oCreateRepos->getHookFile($sClass->POST_REVPROP)
     , File::Spec->rel2abs('post-revprop-change',$sHookDir)
     , "post-revprop hook");

  if ($SWIG_VERSION gt '1.007') {
    is($oCreateRepos->getHookFile($sClass->PRE_OBLITERATE)
       , File::Spec->rel2abs('pre-obliterate',$sHookDir)
       , "pre-obliterate hook");
    is($oCreateRepos->getHookFile($sClass->POST_OBLITERATE)
       , File::Spec->rel2abs('post-obliterate',$sHookDir)
       , "post-obliterate hook");
  }


  #-----------------------------------
  # not tested
  # -----------------------
  # getYoungestRevision($iUTC)
  #

  return $oCreateRepos;

}

#==================================================================
# TEST PLAN
#==================================================================

testEmptyRepository();


__END__

use Test::Mock::DirTree;

#==================================================================
# Test generators
#==================================================================

sub testRepository(;$$$$) {
  my ($xConfig, $xConfigFs) = @_;

  my ($sRoot, $hFiles) = Test::Mock::DirTree::makeFileTree();
  my $oRepos = $TEST_CLASS->create($sRoot, $xConfig, $xConfigFs);

  #Make sure it has the right files
  #Note: this test might depend on the svn version

  my $aFiles = Test::Mock::DirTree::getFiles($sRoot);
  is_deeply([sort @$aFiles]
            , [ sort qw(dav locks hooks conf db format README.txt)]);

  #print STDERR "listing <$sOsPath>: [@$aFiles]\n";
}



#==================================================================
# Test suite
#==================================================================

testRepository();
testRepository(undef, $SVN::Fs::TYPE_FSFS);
testRepository(undef, $SVN::Fs::TYPE_BDB);

