use strict;
use warnings;

package SVN::Friendly::Config;
my $CLASS = __PACKAGE__;

use SVN::Friendly::Utils qw(_shiftBoolean _shiftVisitor);
use SVN::Core;

#------------------------------------------------------------------

use SVN::Friendly::Exceptions;
my $EXCEPTIONS = 'SVN::Friendly::Exceptions';

#------------------------------------------------------------------
# fill in missing constants

{
  package SVN::Core;
  our $CONFIG_SECTION_AUTOPROPS = 'auto-props';
}

#------------------------------------------------------------------

our @CATEGORIES
  = ($SVN::Core::CONFIG_CATEGORY_SERVERS
     , $SVN::Core::CONFIG_CATEGORY_CONFIG
    );

our @SECTIONS
  = ($SVN::Core::CONFIG_SECTION_GROUPS
     , $SVN::Core::CONFIG_SECTION_GLOBAL
     , $SVN::Core::CONFIG_SECTION_AUTH
     , $SVN::Core::CONFIG_SECTION_HELPERS
     , $SVN::Core::CONFIG_SECTION_MISCELLANY
     , $SVN::Core::CONFIG_SECTION_TUNNELS
     , $SVN::Core::CONFIG_SECTION_AUTOPROPS
    );

#==================================================================
# CLASS METHODS
#==================================================================

sub new {
  my ($sClass, $xNative, $oPool) = @_;
  my $sRef = ref($xNative);
  my $hConfig;
  if ($sRef eq 'HASH') {
    $hConfig = $xNative;
  } elsif (!$sRef) {
    $hConfig = SVN::Core::config_get_config($xNative);
  } elsif ($sRef->isa(__PACKAGE__)) {
    return $xNative; #already blessed
  } else {
    die $EXCEPTIONS->ERR_BAD_ARG->new(arg=>$xNative
      , reason => 'value must be directory path, hash, or undefined');
  }

  # Note: we don't create a pool because it is ok to use the
  # global pool

  my $self = { config => $hConfig, pool => $oPool };
  return bless($self, $sClass);
}

#==================================================================
# OBJECT METHODS
#==================================================================

#------------------------------------------------------------------

sub enumerate1_1 {
  my $self      = shift;
  my $oCategory = $self->_shiftCategory(\@_);
  my $sSection  = shift;
  my $crVisit   = _shiftVisitor(\@_);

  SVN::Core::config_enumerate($oCategory, $sSection, $crVisit);
}

sub enumerate1_4 {
  my $self      = shift;
  my $oCategory = $self->_shiftCategory(\@_);
  my $sSection  = shift;
  my $crVisit   = _shiftVisitor(\@_);
  my $oPool     = $self->_shiftPool(\@_);

  SVN::Core::config_enumerate2($oCategory, $sSection,$crVisit,$oPool);
}

*enumerate1_5 = *enumerate1_4;
*enumerate1_6 = *enumerate1_4;
*enumerate1_7 = *enumerate1_4;
*enumerate    = *enumerate1_1;
*visitOptions = *enumerate1_1;

#------------------------------------------------------------------
# Note: this doesn't appear to be included in the 1.4.6 bindings

sub enumerate_sections1_1 {
  my $self      = shift;
  my $oCategory = $self->_shiftCategory(\@_);
  my $crVisit   = _shiftVisitor(\@_);

  #print STDERR "category=<$oCategory> visitor=<$crVisit>\n";
  SVN::Core::config_enumerate_sections($oCategory, $crVisit);
}

sub enumerate_sections1_4 {
  my $self      = shift;
  my $oCategory = $self->_shiftCategory(\@_);
  my $crVisit   = _shiftVisitor(\@_);
  my $oPool     = $self->_shiftPool(\@_);
  SVN::Core::config_enumerate_sections2($oCategory, $crVisit, $oPool);
}

*enumerate_sections1_5 = *enumerate_sections1_4;
*enumerate_sections1_6 = *enumerate_sections1_4;
*enumerate_sections1_7 = *enumerate_sections1_4;
*enumerate_sections    = *enumerate_sections1_1;

#------------------------------------------------------------------
# looks up a server in the groups section and finds the section to
# which it belongs.

sub find_group1_1 {
  my $self           = shift;
  my $oCategory      = $self->_shiftCategory(\@_);
  my $sServer        = shift;
  my $sGroupSection  = _shiftWildcardSection(\@_);
  my $oPool          = $self->_shiftPool(\@_);

  SVN::Core::config_find_group($oCategory, $sServer, $sGroupSection
    , $oPool);
}

*find_group1_4 = *find_group1_1;
*find_group1_5 = *find_group1_1;
*find_group1_6 = *find_group1_1;
*find_group1_7 = *find_group1_1;
*find_group = *find_group1_1;

#------------------------------------------------------------------

sub get1_1 {
  my $self           = shift;
  my $oCategory      = $self->_shiftCategory(\@_);
  my ($sSection, $sOption, $xDefault) = @_;

  # force default value into string - SWIG won't do it for us

  # Need to use SVN::_Core because SVN::Base thinks anything ending
  # in _get is an accessor method and defines it so that the "value"
  # sets data rather than defining a default.

  return SVN::_Core::svn_config_get($oCategory, $sSection, $sOption
    , defined($xDefault)?"$xDefault":undef);
}

*get1_4 = *get1_1;
*get1_5 = *get1_1;
*get1_6 = *get1_1;
*get1_7 = *get1_1;
*get    = *get1_1;

#------------------------------------------------------------------

sub get_bool1_1 {
  my $self           = shift;
  my $oCategory      = $self->_shiftCategory(\@_);
  my $sSection       = shift;
  my $sOption        = shift;
  my $xDefault       = _shiftBoolish(\@_);

  return SVN::Core::config_get_bool($oCategory, $sSection, $sOption
    , $xDefault)?1:0;
}

*get_bool1_4 = *get_bool1_1;
*get_bool1_5 = *get_bool1_1;
*get_bool1_6 = *get_bool1_1;
*get_bool1_7 = *get_bool1_1;
*get_bool    = *get_bool1_1;

#------------------------------------------------------------------

sub getCategoryNames {
  my $self = $_[0];
  return [ keys %{$self->{config}} ];
}

#------------------------------------------------------------------

sub getOptionNames {
  my ($self, $xCategory, $sSection) = @_;
  my @aOptions;
  my $crVisit = sub { push @aOptions, $_[0]; };
  $self->enumerate($xCategory, $sSection, $crVisit);
  return \@aOptions;
}

#------------------------------------------------------------------

sub getSectionNames {
  my ($self, $xCategory) = @_;

  my @aSections;
  my $crVisit = sub { push @aSections, $_[0]; };
  $self->visitSections($xCategory, $crVisit);
  return \@aSections;
}

#------------------------------------------------------------------

sub get_server_setting1_1 {
  my $self           = shift;
  my $oCategory      = $self->_shiftCategory(\@_);
  my ($sServerGroup, $sOption, $xDefault) = @_;

  return SVN::Core::config_get_server_setting($oCategory
    , $sServerGroup, $sOption
    , defined($xDefault)?"$xDefault":undef);
}

*get_server_setting1_4 = *get_server_setting1_1;
*get_server_setting1_5 = *get_server_setting1_1;
*get_server_setting1_6 = *get_server_setting1_1;
*get_server_setting1_7 = *get_server_setting1_1;
*get_server_setting    = *get_server_setting1_1;

#------------------------------------------------------------------

sub get_server_setting_int1_1 {
  my $self           = shift;
  my $oCategory      = $self->_shiftCategory(\@_);
  my ($sServerGroup, $sOption, $xDefault) = @_;

  return SVN::Core::config_get_server_setting_int
    ($oCategory, $sServerGroup, $sOption, $xDefault);
}

*get_server_setting_int1_4 = *get_server_setting_int1_1;
*get_server_setting_int1_5 = *get_server_setting_int1_1;
*get_server_setting_int1_6 = *get_server_setting_int1_1;
*get_server_setting_int1_7 = *get_server_setting_int1_1;
*get_server_setting_int    = *get_server_setting_int1_1;

#------------------------------------------------------------------

sub getCategory { return $_[0]->{config}->{$_[1]}; }

#------------------------------------------------------------------

sub getCategoryHash { return $_[0]->{config} };

#------------------------------------------------------------------

sub hasSection1_1 {
  my ($self, $xCategory, $sSection) = @_;

  # this method doesn't exist in 1_1 so we need to emulate it

  my $iOptionCount = 0;
  $self->enumerate($xCategory, $sSection, sub { $iOptionCount++});
  return $iOptionCount ? 1: 0;
}

sub hasSection1_4 {
  my $self           = shift;
  my $oCategory      = $self->_shiftCategory(\@_);
  my $sSection       = shift;

  SVN::Core::config_has_section($oCategory, $sSection);
}

*hasSection1_5 = *hasSection1_4;
*hasSection1_6 = *hasSection1_4;
*hasSection1_7 = *hasSection1_4;
*hasSection    = *hasSection1_1;

#------------------------------------------------------------------

sub merge1_1 {
  my $self           = shift;
  my $oCategory      = $self->_shiftCategory(\@_);
  my $sFile          = shift;
  my $bMustExist     = _shiftBoolean(\@_);

  SVN::Core::config_merge($oCategory, $sFile, $bMustExist);
}

*merge1_4 = *merge1_1;
*merge1_5 = *merge1_1;
*merge1_6 = *merge1_1;
*merge1_7 = *merge1_1;
*merge    = *merge1_1;

#------------------------------------------------------------------

sub read1_1 {
  my $self           = shift;
  my $sCategory      = _shiftRequiredCategory(\@_);
  my $sFile          = shift;
  my $bMustExist     = _shiftBoolean(\@_);
  my $oPool          = $self->_shiftPool(\@_);

  my $oCategory = SVN::Core::config_read($sFile, $bMustExist,$oPool);
  $self->{config}->{$sCategory} = $oCategory;
}

*read1_4 = *read1_1;
*read1_5 = *read1_1;
*read1_6 = *read1_1;
*read1_7 = *read1_1;
*read    = *read1_1;

#------------------------------------------------------------------

sub set1_1 {
  my $self           = shift;
  my $oCategory      = $self->_shiftCategory(\@_);
  my ($sSection, $sOption, $sValue) = @_;

  # Need to use SVN::_Core because SVN::Base thinks anything ending
  # in _set is a companion method to _get and refuses to import it.

  # need to quote value in case it is a number that needs to be
  # converted to a value - SWIG won't do it for us.

  return SVN::_Core::svn_config_set($oCategory, $sSection, $sOption
    , defined($sValue)?"$sValue":undef);
}

*set1_4 = *set1_1;
*set1_5 = *set1_1;
*set1_6 = *set1_1;
*set1_7 = *set1_1;
*set    = *set1_1;

#------------------------------------------------------------------

sub set_bool1_1 {
  my $self           = shift;
  my $oCategory      = $self->_shiftCategory(\@_);
  my $sSection       = shift;
  my $sOption        = shift;
  my $bValue         = _shiftBoolish(\@_);

  return SVN::Core::config_set_bool($oCategory, $sSection, $sOption
     , $bValue);
}

*set_bool1_4 = *set_bool1_1;
*set_bool1_5 = *set_bool1_1;
*set_bool1_6 = *set_bool1_1;
*set_bool1_7 = *set_bool1_1;
*set_bool    = *set_bool1_1;

#------------------------------------------------------------------

sub visitSections {
  my $self       = shift;
  my $oCategory  = $self->_shiftCategory(\@_);
  my $crVisit    = _shiftVisitor(\@_);

  # Note: we can't use enumerate_sections because the thunk for that
  # method doesn't appear to be set up. As a substitute we enumerate
  # through the hard coded list of sections.
  # BUT note that we will miss any user defined secitons.

  foreach my $sSection (@SECTIONS) {
    next unless $self->hasSection($oCategory, $sSection);
    $crVisit->($_);
  }
}

#------------------------------------------------------------------

# 1.6 only
# - get_server_setting_bool
# - get_yes_no_ask
#
# tools
# - get_user_config_path($sDir, $sName)
# - ensure($sDir, $oPool)
# - read_auth_data($hAuthData, $sCredKind, $sRealm, $sDir, $oPool);
# - $hAuthData = write_auth_data($sCredKind, $sRealm, $sDir, $oPool);
# tools: 1.7 only
# - create($oPool)

#==================================================================
# PRIVATE OBJECT METHODS
#==================================================================

#------------------------------------------------------------------

sub _shiftPool {
  my $self = shift @_;
  die "Not a $CLASS" unless $self->isa($CLASS);

  my $oPool = shift @{shift @_};
  return defined($oPool) ? $oPool : $self->{pool};
}

#------------------------------------------------------------------

sub _shiftCategory {
  my ($self, $aArgs) = @_;
  my $xCategory = shift @$aArgs;
  if (!defined($xCategory)) {
    die $EXCEPTIONS->ERR_UNDEF_ARG->new(param=>'category');
  }
  return ref($xCategory)
    ? $xCategory : $self->getCategory($xCategory);
}

#==================================================================
# UTILITY METHODS
#==================================================================

#------------------------------------------------------------------

sub _shiftBoolish {
  my $aArgs = $_[0];
  my $sBool = shift @$aArgs;
  return !defined($sBool)
    ? 0
    : ($sBool =~ m{^(?:true|yes|on|1)$}i)
       ? 1
       : ($sBool =~ m{^(?:false|no|off|0)}i)
         ? 0 : $sBool;
}

#------------------------------------------------------------------

sub _shiftRequiredCategory {
  my $aArgs = $_[0];
  my $sCategory = shift @$aArgs;
  if (!defined($sCategory)) {
    die $EXCEPTIONS->ERR_UNDEF_ARG->new(param=>'category name');
  }
  return $sCategory;
}

#------------------------------------------------------------------

sub _shiftWildcardSection {
  my $aArgs = $_[0];
  my $sSection = shift @$aArgs;
  return defined($sSection) ? $sSection : 'groups';
}

#==================================================================
# MODULE INITIALIZATION
#==================================================================

1;
