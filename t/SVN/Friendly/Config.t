use strict;
use warnings;
use Test::More tests => 646;

#------------------------------------------------------------------

BEGIN { use_ok('SVN::Friendly::Config') or BAIL_OUT; };
my $TEST_CLASS = "SVN::Friendly::Config";

#------------------------------------------------------------------

my $SKIP_SWIG_BUGS=1;
my $NAG_REPORT_SWIG_BUGS=1;
my %SWIG_BINDING_BUGS;

my @VERSION_SUFFIXES=('', qw(1_1 1_4 1_5 1_6 1_7));

my $IDX_SVN1_4  = 2;
my $WC_LAST_IDX = $IDX_SVN1_4;

#------------------------------------------------------------------

use Exception::Lite;
Exception::Lite::onDie(4);

#------------------------------------------------------------------

use Test::Sandbox qw(makeSandbox);

my $SANDBOX_CLASS = 'Test::Sandbox';
my $SANDBOX = $SANDBOX_CLASS->new($TEST_CLASS);
my $EMPTY_FILE = $SANDBOX->addFile();

#==================================================================
# TEST SUITES
#==================================================================

#==================================================================
# SUBTESTS
#==================================================================

#--------------------------------------------------------------------

sub _isMinimal {
  my $aParams = shift;
  return 0 if scalar(@$aParams);

  for (@_) { return 0 if defined($_) }
  return 1;
}

#------------------------------------------------------------------

sub _okMergeOrRead {
  my ($sName, $oConfig, $sCategory, $hProps, $bMustExist, $aMethods
      , $hExpected) = @_;
  $hExpected = $hProps unless defined($hExpected);

  my $sFile='myconfig.ini';
  my $bExists = defined($hProps)?1:0;
  if ($bExists) {
    $sFile = $SANDBOX->addIniFile(undef, $hProps);
  } else {
    $sFile = $SANDBOX->getNonExistantPathName(1);
  }

  for my $i (0..$WC_LAST_IDX) {
    my $sTest = "$sName$VERSION_SUFFIXES[$i]($sCategory,"
      . ",$sFile, ".($bMustExist?1:0).")";
    my $bDie  = $bMustExist && !$bExists;
    if ($bDie) {
      $sTest = "$sTest: - verifying exception: exception expected "
        ."- file must exist and does not";
    }

    eval {
      $aMethods->[$i]->($sFile);
      if ($bDie) {
        fail($sTest);
      } else {
        pass("$sTest - verifying exception");
      }
      return 1;
    } or do {
      my $e=$@;
      if ($bDie) {
        pass($sTest);
      } else {
        fail("$sTest - unexpected exception: $e");
        next;
      }
    };

    my %hGot;
    while (my ($sSection,$hOptions) = each(%$hExpected)) {
      while (my ($k,$v) = each (%$hOptions)) {
        $hGot{$sSection}{$k}
          = $oConfig->get($sCategory, $sSection, $k);
      }
    }
    is_deeply(\%hGot, $hExpected, "$sTest - verifying properties");
  }
}

#------------------------------------------------------------------

sub okEnumerate {
  my ($sName, $oConfig, $sCategory, $sSection, $aOptions) = @_;
  my @aGotOptions;
  my $crVisit = sub { push @aGotOptions, $_[0] };

  my @aEnumerate
    = ( sub { $oConfig->enumerate($sCategory, $sSection, $crVisit) }
      , sub { $oConfig->enumerate1_1($sCategory, $sSection,$crVisit)}
      , sub { $oConfig->enumerate1_4($sCategory, $sSection,$crVisit)}
      , sub { $oConfig->enumerate1_5($sCategory, $sSection,$crVisit)}
      , sub { $oConfig->enumerate1_6($sCategory, $sSection,$crVisit)}
      , sub { $oConfig->enumerate1_7($sCategory, $sSection,$crVisit)}
      );


  for my $i (0..$WC_LAST_IDX) {
    my $bVerify = 1;
    my $sTest = "$sName: enumerate$VERSION_SUFFIXES[$i]"
      ."($sCategory,$sSection)";

  SKIP:
    {
      if ($SKIP_SWIG_BUGS && ($i >= $IDX_SVN1_4)) {
        my $sBug="commit: svn_enumerate_sections/enumerate_sections2 "
          ."undefined in SWIG-Perl";
        $SWIG_BINDING_BUGS{$sBug}++;
        local $TODO = "SWIG binding bug: need to report\n\t$sBug";
        skip $sTest, 1;
      }

      # use eval so we don't die if $SKIP_SWIG_BUGS=0;

      @aGotOptions=();
      eval { $aEnumerate[$i]->(); return 1 }
        or do { warn "$sTest - warning: $@"; $bVerify = 0; };
      next unless $bVerify;

      is_deeply(\@aGotOptions, $aOptions, $sTest);
    }
  }

  is_deeply($oConfig->getOptionNames($sCategory, $sSection), $aOptions
            , "$sName: getOptionNames($sCategory,$sSection)");

  @aGotOptions=();
  $oConfig->visitOptions($sCategory, $sSection, $crVisit);
  is_deeply(\@aGotOptions, $aOptions
            , "$sName: visitOptions($sCategory,$sSection)");
}

#------------------------------------------------------------------

sub okEnumerate_sections {
  my ($sName, $oConfig, $sCategory, $aSections) = @_;
  my @aGotSections;

  # Note: in 1.5 undef seems to be passed as a section name from
  # time to time. Not sure why but we need to make ure we chck
  # for it.
  my $crVisit = sub { push @aGotSections, $_[0] };

  my @aEnumerateSections
    = ( sub { $oConfig->enumerate_sections($sCategory, $crVisit) }
      , sub { $oConfig->enumerate_sections1_1($sCategory, $crVisit) }
      , sub { $oConfig->enumerate_sections1_4($sCategory, $crVisit) }
      , sub { $oConfig->enumerate_sections1_5($sCategory, $crVisit) }
      , sub { $oConfig->enumerate_sections1_6($sCategory, $crVisit) }
      , sub { $oConfig->enumerate_sections1_7($sCategory, $crVisit) }
      );

  $aSections = [ sort @$aSections ];

  for my $i (0..$WC_LAST_IDX) {
    my $bVerify = 1;
    my $sTest = "$sName: "
      ."enumerateSections$VERSION_SUFFIXES[$i]($sCategory)";

  SKIP:
    {
      if ($SKIP_SWIG_BUGS) {
        my $sBug="commit: svn_enumerate_sections/enumerate_sections2 "
          ."undefined in SWIG-Perl";
        $SWIG_BINDING_BUGS{$sBug}++;
        local $TODO = "SWIG binding bug: need to report\n\t$sBug";
        skip $sTest, 1;
      }

      # use eval so we don't die if $SKIP_SWIG_BUGS=0;

      @aGotSections=();
      eval { $aEnumerateSections[$i]->(); return 1 }
        or do { warn "$sTest - warning: $@"; $bVerify = 0; };
      next unless $bVerify;

      is_deeply([ sort @aGotSections], $aSections, $sTest);
    }
  }

  is_deeply([ sort @{$oConfig->getSectionNames($sCategory)} ], $aSections
            , "$sName: getSectionNames($sCategory)");

  @aGotSections=();
  $oConfig->visitSections($sCategory, $crVisit);
  is_deeply(\@aGotSections, $aSections
    , "$sName: visitSections($sCategory)");
}

#------------------------------------------------------------------

sub okFind_group {
  my ($sName, $oConfig, $sCategory, $sItem, $sWildcardSection
      , $xExpected) = @_;

  my @aFind_group
    = ( sub { $oConfig->find_group($sCategory, $sItem
              , $sWildcardSection) }
      , sub { $oConfig->find_group1_1($sCategory, $sItem
              , $sWildcardSection) }
      , sub { $oConfig->find_group1_4($sCategory, $sItem
              , $sWildcardSection) }
      , sub { $oConfig->find_group1_5($sCategory, $sItem
              , $sWildcardSection) }
      , sub { $oConfig->find_group1_6($sCategory, $sItem
              , $sWildcardSection) }
      , sub { $oConfig->find_group1_7($sCategory, $sItem
              , $sWildcardSection) }
      );

  for my $i (0..$WC_LAST_IDX) {
    my $sTest="find_group$VERSION_SUFFIXES[$i]($sCategory, "
      ."$sItem,"
      . (defined($sWildcardSection)?$sWildcardSection:'undef').")";
    is($aFind_group[$i]->(), $xExpected, $sTest);
  }
}

#------------------------------------------------------------------

sub okGet {
  my ($sName, $oConfig, $sCategory, $sSection, $sOption, $xDefault
      , $xExpected) = @_;

  my @aGet
    = ( sub { $oConfig->get($sCategory, $sSection, $sOption
            , $xDefault) }
      , sub { $oConfig->get1_1($sCategory, $sSection, $sOption
            , $xDefault) }
      , sub { $oConfig->get1_4($sCategory, $sSection, $sOption
            , $xDefault) }
      , sub { $oConfig->get1_5($sCategory, $sSection, $sOption
            , $xDefault) }
      , sub { $oConfig->get1_6($sCategory, $sSection, $sOption
            , $xDefault) }
      , sub { $oConfig->get1_7($sCategory, $sSection, $sOption
            , $xDefault) }
      );

  for my $i (0..$WC_LAST_IDX) {
    is($aGet[$i]->(), $xExpected
       , "get$VERSION_SUFFIXES[$i]($sCategory, $sSection,$sOption,"
       . (defined($xDefault)?$xDefault:'undef').")");
  }
}

#------------------------------------------------------------------

sub okGet_server_setting {
  my ($sName, $oConfig, $sCategory, $sGroup, $sOption, $xDefault
      , $xExpected) = @_;

  my @aGet
    = ( sub { $oConfig->get_server_setting($sCategory, $sGroup
            , $sOption, $xDefault) }
      , sub { $oConfig->get_server_setting1_1($sCategory, $sGroup
            , $sOption, $xDefault) }
      , sub { $oConfig->get_server_setting1_4($sCategory, $sGroup
            , $sOption, $xDefault) }
      , sub { $oConfig->get_server_setting1_5($sCategory, $sGroup
            , $sOption, $xDefault) }
      , sub { $oConfig->get_server_setting1_6($sCategory, $sGroup
            , $sOption, $xDefault) }
      , sub { $oConfig->get_server_setting1_7($sCategory, $sGroup
            , $sOption, $xDefault) }
      );

  for my $i (0..$WC_LAST_IDX) {
    is($aGet[$i]->(), $xExpected
       , "get$VERSION_SUFFIXES[$i]($sCategory, $sGroup,$sOption,"
       . (defined($xDefault)?$xDefault:'undef').")");
  }
}

#------------------------------------------------------------------

sub okGet_server_setting_int {
  my ($sName, $oConfig, $sCategory, $sGroup, $sOption, $xDefault
      , $xExpected) = @_;

  my @aGet
    = ( sub { $oConfig->get_server_setting_int($sCategory, $sGroup
            , $sOption, $xDefault) }
      , sub { $oConfig->get_server_setting_int1_1($sCategory
            , $sGroup, $sOption, $xDefault) }
      , sub { $oConfig->get_server_setting_int1_4($sCategory
            , $sGroup, $sOption, $xDefault) }
      , sub { $oConfig->get_server_setting_int1_5($sCategory
            , $sGroup, $sOption, $xDefault) }
      , sub { $oConfig->get_server_setting_int1_6($sCategory
            , $sGroup, $sOption, $xDefault) }
      , sub { $oConfig->get_server_setting_int1_7($sCategory
            , $sGroup, $sOption, $xDefault) }
      );

  for my $i (0..$WC_LAST_IDX) {
    is($aGet[$i]->(), $xExpected
       , "get$VERSION_SUFFIXES[$i]($sCategory, $sGroup,$sOption,"
       . (defined($xDefault)?$xDefault:'undef').")");
  }
}
#------------------------------------------------------------------

sub okGet_bool {
  my ($sName, $oConfig, $sCategory, $sSection, $sOption, $bDefault
      , $xExpected) = @_;

  my @aGet_bool
    = ( sub { $oConfig->get_bool($sCategory, $sSection, $sOption
            , $bDefault) }
      , sub { $oConfig->get_bool1_1($sCategory, $sSection, $sOption
            , $bDefault) }
      , sub { $oConfig->get_bool1_4($sCategory, $sSection, $sOption
            , $bDefault) }
      , sub { $oConfig->get_bool1_5($sCategory, $sSection, $sOption
            , $bDefault) }
      , sub { $oConfig->get_bool1_6($sCategory, $sSection, $sOption
            , $bDefault) }
      , sub { $oConfig->get_bool1_7($sCategory, $sSection, $sOption
            , $bDefault) }
      );

  for my $i (0..$WC_LAST_IDX) {
    is($aGet_bool[$i]->()?1:0, $xExpected?1:0
       , "get_bool$VERSION_SUFFIXES[$i]($sCategory, $sSection"
       .", $sOption," . (defined($bDefault)?$bDefault:'undef').")");
  }
}

#------------------------------------------------------------------

sub okHasSection {
  my ($sName, $oConfig, $sCategory, $sSection, $bSection) = @_;
  my @aHasSection
    = ( sub { $oConfig->hasSection($sCategory, $sSection) }
      , sub { $oConfig->hasSection1_1($sCategory, $sSection) }
      , sub { $oConfig->hasSection1_4($sCategory, $sSection) }
      , sub { $oConfig->hasSection1_5($sCategory, $sSection) }
      , sub { $oConfig->hasSection1_6($sCategory, $sSection) }
      , sub { $oConfig->hasSection1_7($sCategory, $sSection) }
      );

  for my $i (0..$WC_LAST_IDX) {
    is($aHasSection[$i]->(), $bSection
       , "hasSection$VERSION_SUFFIXES[$i]($sCategory, $sSection)");
  }
}

#------------------------------------------------------------------

sub okMerge {
  my ($sName, $oConfig, $sCategory, $aParams, $hProps
      , $hExpected) = @_;

  $aParams = [] unless defined($aParams);
  my ($bMustExist) = @$aParams;
  my $bMinimal = _isMinimal($aParams);

  my @aMerge = $bMinimal
    ? ( sub { $oConfig->merge($sCategory, $_[0]) }
      , sub { $oConfig->merge1_1($sCategory, $_[0]) }
      , sub { $oConfig->merge1_4($sCategory, $_[0]) }
      , sub { $oConfig->merge1_5($sCategory, $_[0]) }
      , sub { $oConfig->merge1_6($sCategory, $_[0]) }
      , sub { $oConfig->merge1_7($sCategory, $_[0]) }
      )
    : ( sub { $oConfig->merge($sCategory, $_[0], $bMustExist) }
      , sub { $oConfig->merge1_1($sCategory, $_[0], $bMustExist) }
      , sub { $oConfig->merge1_4($sCategory, $_[0], $bMustExist) }
      , sub { $oConfig->merge1_5($sCategory, $_[0], $bMustExist) }
      , sub { $oConfig->merge1_6($sCategory, $_[0], $bMustExist) }
      , sub { $oConfig->merge1_7($sCategory, $_[0], $bMustExist) }
      );

  return _okMergeOrRead("$sName: merge", $oConfig, $sCategory, $hProps
                        , $bMustExist, \@aMerge, $hExpected);
}

#------------------------------------------------------------------

sub okRead {
  my ($sName, $oConfig, $sCategory, $aParams, $hProps) = @_;

  $aParams = [] unless defined($aParams);
  my ($bMustExist) = @$aParams;
  my $bMinimal = _isMinimal($aParams);

  my @aRead = $bMinimal
    ? ( sub { $oConfig->read($sCategory, $_[0]) }
      , sub { $oConfig->read1_1($sCategory, $_[0]) }
      , sub { $oConfig->read1_4($sCategory, $_[0]) }
      , sub { $oConfig->read1_5($sCategory, $_[0]) }
      , sub { $oConfig->read1_6($sCategory, $_[0]) }
      , sub { $oConfig->read1_7($sCategory, $_[0]) }
      )
    : ( sub { $oConfig->read($sCategory, $_[0], $bMustExist) }
      , sub { $oConfig->read1_1($sCategory, $_[0], $bMustExist) }
      , sub { $oConfig->read1_4($sCategory, $_[0], $bMustExist) }
      , sub { $oConfig->read1_5($sCategory, $_[0], $bMustExist) }
      , sub { $oConfig->read1_6($sCategory, $_[0], $bMustExist) }
      , sub { $oConfig->read1_7($sCategory, $_[0], $bMustExist) }
      );

  return _okMergeOrRead("$sName: read", $oConfig, $sCategory, $hProps
                        , $bMustExist, \@aRead, $hProps);
}

#------------------------------------------------------------------

sub okSet {
  my ($sName, $oConfig, $sCategory, $sSection, $sOption, $xValue)= @_;

  my @aSet
    = ( sub { $oConfig->set($sCategory, $sSection, $sOption
            , $xValue) }
      , sub { $oConfig->set1_1($sCategory, $sSection, $sOption
            , $xValue) }
      , sub { $oConfig->set1_4($sCategory, $sSection, $sOption
            , $xValue) }
      , sub { $oConfig->set1_5($sCategory, $sSection, $sOption
            , $xValue) }
      , sub { $oConfig->set1_6($sCategory, $sSection, $sOption
            , $xValue) }
      , sub { $oConfig->set1_7($sCategory, $sSection, $sOption
            , $xValue) }
      );

  for my $i (0..$WC_LAST_IDX) {
    $aSet[$i]->();
    is($oConfig->get($sCategory, $sSection, $sOption), $xValue
       , "set$VERSION_SUFFIXES[$i]($sCategory, $sSection)");
  }
}

#--------------------------------------------------------------------

sub okSet_bool {
  my ($sName, $oConfig, $sCategory, $sSection, $sOption, $bValue
     , $bExpected)=@_;

  my @aSet_bool
    = ( sub { $oConfig->set_bool($sCategory, $sSection, $sOption
            , $bValue) }
      , sub { $oConfig->set_bool1_1($sCategory, $sSection, $sOption
            , $bValue) }
      , sub { $oConfig->set_bool1_4($sCategory, $sSection, $sOption
            , $bValue) }
      , sub { $oConfig->set_bool1_5($sCategory, $sSection, $sOption
            , $bValue) }
      , sub { $oConfig->set_bool1_6($sCategory, $sSection, $sOption
            , $bValue) }
      , sub { $oConfig->set_bool1_7($sCategory, $sSection, $sOption
            , $bValue) }
      );

  for my $i (0..$WC_LAST_IDX) {
    $aSet_bool[$i]->();

    # set default to opposite of expected value so we know that we
    # got the actual value rather than some default.

    is($oConfig->get_bool($sCategory, $sSection, $sOption
                          , !$bExpected), $bExpected
       , "set_bool$VERSION_SUFFIXES[$i]($sCategory, $sSection,"
       ."$sOption, ".(defined($bValue)?$bValue:'undef').")");
  }
}

#--------------------------------------------------------------------

sub testEmptyConfig {
  my ($sName, $oConfig) = @_;

  is_deeply($oConfig->getCategoryNames()
   , \@SVN::Friendly::Config::CATEGORIES, "$sName: getCategoryNames");

  for my $sCategory (@SVN::Friendly::Config::CATEGORIES) {

    # force an empty configuration - depending on the subversion release
    # and possibly the OS, subversion may be pre-configured with some
    # data.

    $oConfig->read($sCategory, $EMPTY_FILE);
    okEnumerate_sections($sName, $oConfig, $sCategory => []);
    for my $sSection (@SVN::Friendly::Config::SECTIONS) {
      # tunnels has very different content between 1.4 and 1.5, so just
      # skip it.
      #next if $sSection eq $SVN::Core::CONFIG_SECTION_TUNNELS;
      okHasSection($sName, $oConfig, $sCategory, $sSection => 0);
      okEnumerate($sName, $oConfig, $sCategory, $sSection => []);
    }
  }

  my $sCategory = $SVN::Core::CONFIG_CATEGORY_CONFIG;
  my $sSection  = $SVN::Core::CONFIG_SECTION_GLOBAL;
  my $sOption   = $SVN::Core::CONFIG_OPTION_HTTP_TIMEOUT;

  testGetSet($sName, $oConfig, $sCategory, $sSection, $sOption);

  my $hProps = { groups => { perl => '*.perl.org'
                             , apache => '*.apache.org'
                           }
               , xxx => { opt1 => '*.x.y.z'
                        , opt2 => '1.2.3.*'
                        }
               };

  # does read work

  okRead($sName, $oConfig, $sCategory, [1], undef, {});
  okRead($sName, $oConfig, $sCategory, [], $hProps, $hProps);
  okHasSection($sName, $oConfig, $sCategory, 'groups', => 1);
  okHasSection($sName, $oConfig, $sCategory, 'xxx', => 1);

  # KNOWN_BUG-non-standard sections not found when we enumerate sections
  # - enumerate_sections is not defined in the API so we have to fake it
  my $aExpected = $SKIP_SWIG_BUGS ? ['groups'] : [qw(groups xxxx)];
  okEnumerate_sections($sName, $oConfig, $sCategory => $aExpected);

  # does merge work?
  my $hChanges = { groups => { google => '*.google.com' }
                   , xxx => { opt1 => '*.a.b.c' }
                   , yyy => { mary => 'lamb'
                              , boPeep => 'sheep'
                            }
                 };

  $hProps->{groups}        = { %{$hProps->{groups}}
                              , %{$hChanges->{groups}}
                             };
  $hProps->{xxx}{opt1} = $hChanges->{xxx}{opt1};
  $hProps->{yyy}       = $hChanges->{yyy};

  okMerge($sName, $oConfig, $sCategory, [1], undef, {});
  okMerge($sName, $oConfig, $sCategory, [], $hChanges, $hProps);


  # does find work?
  okFind_group($sName, $oConfig, $sCategory
               , 'perldoc.perl.org', 'groups', 'perl');
  okFind_group($sName, $oConfig, $sCategory
               , 'perldoc.perl.org', undef, 'perl');
  okFind_group($sName, $oConfig, $sCategory
               , '1.2.3.4', 'xxx', 'opt2');

  return $oConfig;
}

#--------------------------------------------------------------------

sub testGetSet {
  my ($sName, $oConfig, $sCategory, $sSection, $sOption) = @_;

  okGet($sName, $oConfig, $sCategory, $sSection, $sOption, 42=>42);
  okSet($sName, $oConfig, $sCategory, $sSection, $sOption, 'none'
        => 'none');
  okSet($sName, $oConfig, $sCategory, $sSection, $sOption, 10 => 10);
  okGet($sName, $oConfig, $sCategory, $sSection, $sOption, 42=>10);
  okGet_server_setting($sName, $oConfig, $sCategory, $sSection
    , $sOption, 42 => 10);
  okGet_server_setting_int($sName, $oConfig, $sCategory, $sSection
    , $sOption, 42 => 10);

  # try out different true/false values

  okSet_bool($sName, $oConfig, $sCategory, $sSection, $sOption, 1
             => 1);
  okSet_bool($sName, $oConfig, $sCategory, $sSection, $sOption, 0
             => 0);
  okSet_bool($sName, $oConfig, $sCategory, $sSection, $sOption,'TRUE'
             => 1);
  okSet_bool($sName, $oConfig, $sCategory, $sSection, $sOption,'FALSE'
             => 0);
  okSet_bool($sName, $oConfig, $sCategory, $sSection, $sOption,'true'
             => 1);
  okSet_bool($sName, $oConfig, $sCategory, $sSection, $sOption,'false'
             => 0);
  okSet_bool($sName, $oConfig, $sCategory, $sSection, $sOption, 'on'
             => 1);
  okSet_bool($sName, $oConfig, $sCategory, $sSection, $sOption, 'off'
             => 0);

  # make sure that undef converts to 0 instead of causing an exception
  $oConfig->set_bool($sCategory, $sSection, $sOption, 1);
  okSet_bool($sName, $oConfig, $sCategory, $sSection, $sOption, undef
             => 0);
  okGet_bool($sName, $oConfig, $sCategory, $sSection, $sOption, 42
             =>0);
}

#==================================================================
# TEST PLAN
#==================================================================

testEmptyConfig('empty=undef', $TEST_CLASS->new());
testEmptyConfig('empty=config', $TEST_CLASS->new($TEST_CLASS->new()));
testEmptyConfig('empty=newdir', $TEST_CLASS->new($SANDBOX->addDir()));

if ($NAG_REPORT_SWIG_BUGS && keys %SWIG_BINDING_BUGS) {
  my $sMsg="SWIG binding bugs found: need to report";
  $sMsg .= "\n\t$_" for keys %SWIG_BINDING_BUGS;
  diag("\n\n$sMsg\n\n");
};
