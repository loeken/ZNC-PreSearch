##
# PreSearch module for ZNC IRC Bouncer
# Author: m4luc0
# Version: 1.4
##

package presearch;
use base 'ZNC::Module';

use POE::Component::IRC::Common; # needed for stripping message colors and formatting
use DBI;                         # needed for DB connection
use experimental 'smartmatch';   # smartmatch (Regex) support for newer perl versions
use IRC::Utils qw(NORMAL BOLD UNDERLINE REVERSE ITALIC FIXED WHITE BLACK BLUE GREEN RED BROWN PURPLE ORANGE YELLOW LIGHT_GREEN TEAL LIGHT_CYAN LIGHT_BLUE PINK GREY LIGHT_GREY); # Support for IRC colors and formatting

# (My)SQL settings
my $DB_NAME     = 'dbname';      # DB name
my $DB_TABLE    = 'table';   # TABLE name
my $DB_HOST     = 'localhost';   # DB host
my $DB_USER     = 'dbuser';      # DB user
my $DB_PASSWD   = 'passwerd';      # DB user passwd

# DB Columns
my $COL_PRETIME = 'ctime';     # pre timestamp
my $COL_RELEASE = 'rlsname';     # release name
my $COL_SECTION = 'section';     # section name
my $COL_FILES   = 'files';       # number of files
my $COL_SIZE    = 'size';        # release size
my $COL_STATUS  = 'status';      # 0:pre; 1:nuked; 2:unnuked; 3:delpred; 4:unde$
my $COL_REASON  = 'nukereason';      # reason for nuke/unnuke/delpre/undelpre
my $COL_GROUP   = 'grp';       # groupname

sub description {
    "PreSearch Perl module for ZNC"
}

sub OnChanMsg {
    # get message informations
    my $self = shift;
    my ($nick, $chan, $message) = @_;
    $chan = $chan->GetName;
    $nick = $nick->GetNick;

    # Strip colors and formatting
    if (POE::Component::IRC::Common::has_color($message)) {
        $message = POE::Component::IRC::Common::strip_color($message);
    }
    if (POE::Component::IRC::Common::has_formatting($message)) {
        $message = POE::Component::IRC::Common::strip_formatting($message);
    }

    # Match the first command like "!command"
    my ($cmd, $arguments) = parseCommandLine($message);


    #$self->PutModule("nick: " . $nick . " chan: " . $chan . " message: " . $message);
    # Command?
    if ($cmd) {
        # Yes, so compare different types of commands and return it to the sender
        # !pre release
        if ($cmd eq "!pre" && $arguments) {
            # Search for pre
            $self->searchPre($chan, $arguments);

        # !dupe bla bla bla
        } elsif ($cmd eq "!dupe" && $arguments) {
            $match = $message ~~ m/^!\w+\s(.*)/;

            # Search for dupes
            $self->searchDupe($chan, $arguments);

        # !grp group (section)
        } elsif ($cmd ~~ m/!grp|!group/i) {
            $match = $message ~~ m/^!\w+\s(.*)\s(.*)$/;

            # Search for group releases
            if ($match) {
                $self->group($chan, $1, $2);
            } else {
                $match = $message ~~ m/^!\w+\s(.*)/;
                $self->group($chan, $1);
            }

        # !new section
        } elsif ($cmd eq "!new") {
            $match = $message ~~ m/^!\w+\s(.*)/;

            # Search foo dupes
            $self->newest($chan, $1);

        # !nukes (group/section -g/-s)
        } elsif ($cmd eq "!nukes") {
            $match = $message ~~ m/^!\w+\s(.*)\s(.*)$/;

            # Get nukes
            if ($match) {
                $self->nukes($chan, $1, $2);
            } else {
                $self->nukes($chan);
            }

        # !top (section)
        } elsif ($cmd eq "!top") {
            # Get All-Time top groups
            if (!$arguments) {
                $self->topGroups($chan);
            # Get top groups by section
            } else {
                $self->topSectionGroups($chan, $arguments);
            }

        # !day, !today, !week, !month, !year
        } elsif ($cmd ~~ m/!day|!today|!week|!month|!year/i) {
            # Get stats by time period
            $self->periodStats($chan, $cmd);

        # !stats (group)
        } elsif ($cmd eq "!stats") {
            # Get extended DB stats
            if (!$arguments) {
                $self->extendedStats($chan);
            # Get group stats
            } else {
                $self->groupStats($chan, $arguments);
            }

        # !db
        } elsif ($cmd eq "!db") {
            # Get short DB stats
            $self->shortStats($chan);

        # !help
        } elsif($cmd ~~ m/!help|!cmds/i) {
            # Search foo pre
            $self->searchHelp($chan);
        }
    }

    return $ZNC::CONTINUE;
}

# Parse command line
# returns if it's a valid command line
# an array with $cmd and $arguments
sub parseCommandLine{
  my ( $command ) = @_;
  if( $command =~ m/^((!\w+)((\s+[^ ]+)+)?)/g ){
    my $cmd = $2;
    my $arguments = $3;
    if( $arguments ){
      $arguments =~ s/^\s+//;
    }
    return @array = ($cmd, $arguments);
  }

}

##
# !pre
# !dupe
##

# Search pre
# Param (nick, release)
sub searchPre {
    my $self = shift;
    my ($nick, $release) = @_;
    my $result;

    # Connect to Database
    my $dbh = DBI->connect("DBI:mysql:database=$DB_NAME;host=$DB_HOST", $DB_USER, $DB_PASSWD)
        or die "Couldn't connect to database: " . DBI->errstr;

    # Prepare Query -> Get Release
    my $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM  `".$DB_TABLE."` WHERE `".$COL_RELEASE."` LIKE ? LIMIT 1;");
    # Execute Query
    $query->execute($release) or die $dbh->errstr;

    # Get rows
    my $rows = $query->rows();
    # Do we have a result?
    if ($rows > 0) {
        # set variables
        my ($id, $pretime, $pre, $section, $files, $size, $status, $reason, $group) = $query->fetchrow();


        $pretime = $self->get_time_since($pretime);
        $section = $self->getSection($section);
        $size = $self->getSize($size);

        # SECTION + RELEASE
        $result .= $section." ".$pre." ".$pretime;

        # FILES + SIZE?
        if ($files > 0 or $size > 0) {
            $result .= GREY." - [".NORMAL.$files.ORANGE."F".NORMAL." - ".$size.GREY."] ".NORMAL;
        }

        # NUKED or DEL?
        if ($status eq 1 or $status eq 3) {
            $status = $self->getType($status);
            $result .= " - ".$status.RED.": ".$reason;
        }

    } else  {
        $result .= BOLD."Sorry!".NORMAL." Found nothing about '".BOLD.UNDERLINE.$release.NORMAL."'";
    }

    # Finish query
    $query->finish();

    # Disconnect Database
    $dbh->disconnect();

    # return result
    $self->sendMessage($nick, $result);
}

# Search dupe
# Param (nick, release)
sub searchDupe {
    my $self = shift;
    my ($nick, $param) = @_;
    my $release = "%".$param."%";
    my $result;

    # Replace whitespaces with % (for the SQL search query)
    if ($release ~~ m/\s+/) {
        $release =~ s/\s/%/g;
    }

    # Connect to Database
    my $dbh = DBI->connect("DBI:mysql:database=$DB_NAME;host=$DB_HOST", $DB_USER, $DB_PASSWD)
        or die "Couldn't connect to database: " . DBI->errstr;

    # Prepare Query -> Get Releases
    my $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM  `".$DB_TABLE."` WHERE LOWER(`".$COL_RELEASE."`) LIKE LOWER( ? ) ORDER BY `".$COL_PRETIME."` DESC LIMIT 10;");

    # Execute Query
    $query->execute($release) or die $dbh->errstr;

    # Get rows
    my $rows = $query->rows();
    # Do we have results?
    if ($rows > 0) {
        # Less than 10 results? Return the results number
        if ($rows < 10) {
            $result = $rows > 1 ? "results": "result";
            $self->sendMessage($nick, "Found ".BOLD.UNDERLINE.$rows.NORMAL." ".$result." for '".BOLD.UNDERLINE.$param.NORMAL."'");
        } else {
            $self->sendMessage($nick, "Last 10 results for '".BOLD.UNDERLINE.$param.NORMAL."'");
        }

        # Get results
        my $i = 0;
        while ($i < $rows) {
            # Set variables
            my ($id, $pretime, $pre, $section, $files, $size, $status, $reason, $group) = $query->fetchrow();
            $pretime = $self->get_time_since($pretime);
            $section = $self->getSection($section);
            $size = $self->getSize($size);

            # SECTION + RELEASE
            $result = $section." ".$pre." ".$pretime;

            # FILES + SIZE?
            if ($files > 0 or $size > 0) {
                $result .= GREY." - [".NORMAL.$files.ORANGE."F".NORMAL." - ".$size.GREY."] ".NORMAL;
            }

            # NUKED or DEL?
            if ($status eq 1 or $status eq 3) {
                $status = $self->getType($status);
                $result .= " - ".$status.RED.": ".$reason;
            }

            # Return result
            $self->sendMessage($nick, $result);
            $i++;
        }
    } else  {
        $self->sendMessage($nick, BOLD."Sorry!".NORMAL." Found nothing about '".BOLD.UNDERLINE.$param.NORMAL."'");
    }

    # Finish query
    $query->finish();

    # Disconnect Database
    $dbh->disconnect();
}

##
# !grp group (section)
##

# Search grp releases
# Param (nick, group, section)
sub group {
    my $self = shift;
    my ($nick, $group, $section) = @_;
    my $result;
    my $query;

    # Connect to Database
    my $dbh = DBI->connect("DBI:mysql:database=$DB_NAME;host=$DB_HOST", $DB_USER, $DB_PASSWD)
        or die "Couldn't connect to database: " . DBI->errstr;

    # Prepare Query
    # Get group releases by section
    if (defined $section) {
        $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM  `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND LOWER(`".$COL_SECTION."`) LIKE LOWER( ? ) ORDER BY `".$COL_PRETIME."` DESC LIMIT 0, 10;");
        # Execute Query
        $query->execute($group, "%".$section."%") or die $dbh->errstr;
        $section = uc($self->getSection($section));
        $section = " in ".$section;
    # Get group releases
    } else {
        $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM  `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) ORDER BY `".$COL_PRETIME."` DESC LIMIT 0, 10;");
        # Execute Query
        $query->execute($group) or die $dbh->errstr;
        $section = "";
    }

    # Get rows
    my $rows = $query->rows();
    # Do we have results?
    if ($rows > 0) {
        # Less than 10 results? Return the results number
        if ($rows < 10) {
            $result = $rows > 1 ? "results": "result";
            $self->sendMessage($nick, "Found ".BOLD.UNDERLINE.$rows.NORMAL." ".$result." for '".BOLD.UNDERLINE.$group.NORMAL."'".$section);
        } else {
            $self->sendMessage($nick, "Last 10 results for '".BOLD.UNDERLINE.$group.NORMAL."'".$section);
        }

        # Get results
        my $i = 0;
        while ($i < $rows) {
            # Set variables
            my ($id, $pretime, $pre, $section, $files, $size, $status, $reason, $group) = $query->fetchrow();
            $pretime = $self->get_time_since($pretime);
            $section = $self->getSection($section);
            $size = $self->getSize($size);

            # SECTION + RELEASE
            $result = $section." ".$pre." ".$pretime;

            # FILES + SIZE?
            if ($files > 0 or $size > 0) {
                $result .= GREY." - [".NORMAL.$files.ORANGE."F".NORMAL." - ".$size.GREY."] ".NORMAL;
            }

            # NUKED or DEL?
            if ($status eq 1 or $status eq 3) {
                $status = $self->getType($status);
                $result .= " - ".$status.RED.": ".$reason;
            }

            # Return result
            $self->sendMessage($nick, $result);
            $i++;
        }
    } else  {
        $self->sendMessage($nick, BOLD."Sorry!".NORMAL." Found nothing about '".BOLD.UNDERLINE.$group.NORMAL."'".$section);
    }

    # Finish query
    $query->finish();

    # Disconnect Database
    $dbh->disconnect();
}

##
# !nukes group/section -g -s
##

# Search for nukes
# Param (nick, group/section, g/s)
sub nukes {
    my $self = shift;
    my ($nick, $param, $type) = @_;
    my $result = "";
    my $query;

    # Connect to Database
    my $dbh = DBI->connect("DBI:mysql:database=$DB_NAME;host=$DB_HOST", $DB_USER, $DB_PASSWD)
        or die "Couldn't connect to database: " . DBI->errstr;

    # Prepare Query
    # Get nukes by group
    if (defined $type and $type eq "-g") {
        $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM  `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_STATUS."` LIKE '1' ORDER BY `".$COL_PRETIME."` DESC LIMIT 0, 10;");
        $result = " from '".BOLD.UNDERLINE.$param.NORMAL."'";
        # Execute Query
        $query->execute($param) or die $dbh->errstr;
    # Get nukes by section
    } elsif (defined $type and $type eq "-s") {
        $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM  `".$DB_TABLE."` WHERE LOWER(`".$COL_SECTION."`) LIKE LOWER( ? ) AND `".$COL_STATUS."` LIKE '1' ORDER BY `".$COL_PRETIME."` DESC LIMIT 0, 10;");
        $result = " in '".BOLD.UNDERLINE.$param.NORMAL."'";
        # Execute Query
        $query->execute($param) or die $dbh->errstr;
    } else {
    # Get last nukes
        $query = $dbh->prepare("SELECT  FROM  `".$DB_TABLE."` WHERE `".$COL_STATUS."` LIKE '1' ORDER BY `".$COL_PRETIME."` DESC LIMIT 0, 10;");
        # Execute Query
        $query->execute() or die $dbh->errstr;
    }

    # Get rows
    my $rows = $query->rows();
    # Do we have results?
    if ($rows > 0) {
        # Less than 10 results? Return the results number
        if ($rows < 10) {
            $self->sendMessage($nick, "Found ".BOLD.UNDERLINE.$rows.NORMAL." nukes".$result);
        } else {
            $self->sendMessage($nick, "Last 10 nukes".$result);
        }

        # Get results
        my $i = 0;
        while ($i < $rows) {
            # Set variables
            my ($id, $pretime, $pre, $section, $files, $size, $status, $reason, $group) = $query->fetchrow();
            $pretime = $self->get_time_since($pretime);
            $section = $self->getSection($section);
            $size = $self->getSize($size);

            # SECTION + RELEASE
            $result = $section." ".$pre." ".$pretime;

            # FILES + SIZE?
            if ($files > 0 or $size > 0) {
                $result .= GREY." - [".NORMAL.$files.ORANGE."F".NORMAL." - ".$size.GREY."] ".NORMAL;
            }

            # NUKED or DEL?
            if ($status eq 1 or $status eq 3) {
                $status = $self->getType($status);
                $result .= " - ".$status.RED.": ".$reason;
            }

            # Return result
            $self->sendMessage($nick, $result);
            $i++;
        }
    } else  {
        $self->sendMessage($nick, BOLD."Sorry!".NORMAL." Found no nukes".$result);
    }

    # Finish query
    $query->finish();

    # Disconnect Database
    $dbh->disconnect();
}

##
# !new section
##

# Show the newest releases of a section.
# Param (nick, section)
sub newest {
    my $self = shift;
    my ($nick, $param) = @_;
    my $sec = "%".$param."%";
    my $result;

    # Replace whitespaces with % (for the SQL search query)
    if ($sec ~~ m/\s+/) {
        $sec =~ s/\s/%/g;
    }

    # Connect to Database
    my $dbh = DBI->connect("DBI:mysql:database=$DB_NAME;host=$DB_HOST", $DB_USER, $DB_PASSWD)
        or die "Couldn't connect to database: " . DBI->errstr;

    # Prepare Query -> Get newest section releases
    my $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_SECTION."`) LIKE LOWER( ? ) ORDER BY `".$COL_PRETIME."` DESC LIMIT 0, 10;");

    # Execute Query
    $query->execute($sec) or die $dbh->errstr;

    # Get rows
    my $rows = $query->rows();
    # Do we have results?
    if ($rows > 0) {
        $sec = uc($self->getSection($param));
        # Less than 10 results? Return the results number
        if ($rows < 10) {
            $result = $rows > 1 ? "results": "result";
            $self->sendMessage($nick, "Found ".BOLD.UNDERLINE.$rows.NORMAL." ".$result." for ".$sec);
        } else {
            $self->sendMessage($nick, "Last 10 results for ".$sec);
        }

        # Get results
        my $i = 0;
        while ($i < $rows) {
            # Set variables
            my ($id, $pretime, $pre, $section, $files, $size, $status, $reason, $group) = $query->fetchrow();
            $pretime = $self->get_time_since($pretime);
            $section = $self->getSection($section);
            $size = $self->getSize($size);

            # SECTION + RELEASE
            $result = $section." ".$pre." ".$pretime;

            # FILES + SIZE?
            if ($files > 0 or $size > 0.00) {
                $result .= GREY." - [".NORMAL.$files.ORANGE."F".NORMAL." - ".$size.GREY."] ".NORMAL;
            }

            # NUKED or DEL?
            if ($status eq 1 or $status eq 3) {
                $status = $self->getType($status);
                $result .= " - ".$status.RED.": ".$reason;
            }

            # Return result
            $self->sendMessage($nick, $result);
            $i++;
        }
    } else  {
        $self->sendMessage($nick, BOLD."Sorry!".NORMAL." Found nothing about '".BOLD.UNDERLINE.$param.NORMAL."'");
    }

    # Finish query
    $query->finish();

    # Disconnect Database
    $dbh->disconnect();
}

##
# !top
# !top section
##

# Shows the alltime top10 groups
# Param (nick)
sub topGroups {
    my $self = shift;
    my $nick = $_[0];

    # Connect to Database
    my $dbh = DBI->connect("DBI:mysql:database=$DB_NAME;host=$DB_HOST", $DB_USER, $DB_PASSWD)
        or die "Couldn't connect to database: " . DBI->errstr;

    # Prepare Query -> Get top5 groups
    my $query = $dbh->prepare("SELECT COUNT(`".$COL_RELEASE."`) as `rls`, `".$COL_GROUP."` FROM  `".$DB_TABLE."` WHERE `".$COL_GROUP."` NOT LIKE '' GROUP BY `".$COL_GROUP."` ORDER BY `rls` DESC LIMIT 10;");

    # Execute Query
    $query->execute() or die $dbh->errstr;

    # Get results
    my $rows = $query->rows();
    if ($rows > 0) {
        $self->sendMessage($nick, "These are the All-Time Top 10 groups:");

        my $i = 0;
        while ($i < $rows) {
            my ($group_count, $group) = $query->fetchrow();
            # 1. GROUP - 12345 rls
            $self->sendMessage($nick, GREY.($i+1).".".ORANGE." ".$group.NORMAL." - ".$group_count.NORMAL." rls");
            $i++;
        }
    } else {
        $self->sendMessage($nick, BOLD."Sorry!".NORMAL." No ranking found, PreDB must be empty.");
    }

    # Finish query
    $query->finish();

    # Disconnect Database
    $dbh->disconnect();
}

# Shows the alltime top5 groups of a section
# Param (nick, section)
sub topSectionGroups {
    my $self = shift;
    my ($nick, $param) = @_;
    my $sec = "%".$param."%";

    # Replace whitespaces with % (for the SQL search query)
    if ($sec ~~ m/\s+/) {
        $sec =~ s/\s/%/g;
    }

    # Connect to Database
    my $dbh = DBI->connect("DBI:mysql:database=$DB_NAME;host=$DB_HOST", $DB_USER, $DB_PASSWD)
        or die "Couldn't connect to database: " . DBI->errstr;

    # Prepare Query -> Get top5 groups
    my $query = $dbh->prepare("SELECT COUNT(`".$COL_RELEASE."`) as `rls`, `".$COL_GROUP."` FROM  `".$DB_TABLE."` WHERE LOWER(`".$COL_SECTION."`) LIKE LOWER( ? ) AND `".$COL_GROUP."` NOT LIKE '' GROUP BY `".$COL_GROUP."` ORDER BY `rls` DESC LIMIT 5;");

    # Execute Query
    $query->execute($sec) or die $dbh->errstr;

    # Get results
    my $rows = $query->rows();
    if ($rows > 0) {
        $sec = uc($self->getSection($param));
        # Less than 5 results? Return the results number
        if ($rows < 5) {
            my $result = $rows > 1 ? "groups": "group";
            $self->sendMessage($nick, "Top ".BOLD.UNDERLINE.$rows.NORMAL." ".$result." for ".$sec);
        } else {
            $self->sendMessage($nick, "Top 5 groups for ".$sec);
        }

        # Return placement
        my $i = 0;
        while ($i < $rows) {
            my ($group_count, $group) = $query->fetchrow();
            # 1. GROUP - 12345 rls
            $self->sendMessage($nick, GREY.($i+1).".".ORANGE." ".$group.NORMAL." - ".$group_count.NORMAL." rls");
            $i++;
        }
    } else {
        $self->sendMessage($nick, BOLD."Sorry!".NORMAL." Found no ranking for '".BOLD.UNDERLINE.$param.NORMAL."'");
    }

    # Finish query
    $query->finish();

    # Disconnect Database
    $dbh->disconnect();
}

##
# !db
# !stats (group)
# !day, !today, !week, !month, !year
##

# Short DB stats
# Param (nick)
sub shortStats {
    my $self = shift;
    my $nick = $_[0];

    $self->sendMessage($nick, BOLD."Short PreDB stats".NORMAL);

    # Connect to Database
    my $dbh = DBI->connect("DBI:mysql:database=$DB_NAME;host=$DB_HOST", $DB_USER, $DB_PASSWD)
        or die "Couldn't connect to database: " . DBI->errstr;

    # 0. PRE
    my $query = $dbh->prepare("
        SELECT COUNT(*) FROM `".$DB_TABLE."`;");
    $query->execute() or die $dbh->errstr;
    my $count = $query->fetchrow();
    $self->sendMessage($nick, GREEN."PRED: ".NORMAL.$count);

    # 1. NUKED
    $count = $query->fetchrow();
    #$self->sendMessage($nick, RED."NUKED: ".NORMAL.$count);

    # 2, UNNUKED
    $count = $query->fetchrow();
    #$self->sendMessage($nick, ORANGE."UNNUKED: ".NORMAL.$count);

    # 3. DELPRED
    $count = $query->fetchrow();
    #$self->sendMessage($nick, RED."DEL: ".NORMAL.$count);

    # 4. UNDELPRED
    $count = $query->fetchrow();
    #$self->sendMessage($nick, ORANGE."UNDEL: ".NORMAL.$count);

    # FILES + SIZE
    $query = $dbh->prepare("SELECT SUM(".$COL_FILES."), SUM(".$COL_SIZE.") FROM `".$DB_TABLE."`;");
    $query->execute() or die $dbh->errstr;
    my ($files, $size) = $query->fetchrow();
    $size = $self->getSize($size);
    $self->sendMessage($nick, $files.ORANGE." FILES".NORMAL." - ".$size);

    # Finish query
    $query->finish();

    # Disconnect Database
    $dbh->disconnect();
}

# Extended DB stats
# Param (nick)
sub extendedStats {
    my $self = shift;
    my $nick = $_[0];

    $self->sendMessage($nick, BOLD.ORANGE."PreDB".NORMAL." stats");

    # Connect to Database
    my $dbh = DBI->connect("DBI:mysql:database=$DB_NAME;host=$DB_HOST", $DB_USER, $DB_PASSWD)
        or die "Couldn't connect to database: " . DBI->errstr;

    # PRE
    my $query = $dbh->prepare("SELECT count(*) FROM `".$DB_TABLE."`;");
    $query->execute() or die $dbh->errstr;
    my $count = $query->fetchrow();
    $self->sendMessage($nick, BOLD."PRED: ".NORMAL.ORANGE.$count);

    # FILE/SIZE INFO
    $query = $dbh->prepare("SELECT COUNT(*) FROM `".$DB_TABLE."` WHERE `".$COL_SIZE."` > '0';");
    $query->execute() or die $dbh->errstr;
    $count = $query->fetchrow();
    my $result = BOLD."FILE/SIZE INFOS: ".NORMAL.ORANGE.$count;

    # FILES + SIZE
    $query = $dbh->prepare("SELECT SUM(".$COL_FILES."), SUM(".$COL_SIZE.") FROM `".$DB_TABLE."`;");
    $query->execute() or die $dbh->errstr;
    my ($files, $size) = $query->fetchrow();
    $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
    $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
    $self->sendMessage($nick, $result.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

    # FINE
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` = '0';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
    $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
    $self->sendMessage($nick, BOLD."FINE: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

    # PROPER
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_RELEASE."`) LIKE LOWER('%proper%') AND `".$COL_STATUS."` LIKE '0';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    if ($count > 0) {
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD."PROPER: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
    }

    # INTERNAL
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_RELEASE."`) LIKE LOWER('%internal%') AND `".$COL_STATUS."` LIKE '0';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    if ($count > 0) {
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD."INTERNALS: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
    }

    # REPACKS
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_RELEASE."`) LIKE LOWER('%repack%') AND `".$COL_STATUS."` LIKE '0';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    if ($count > 0) {
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD."REPACKS: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
    }

    # FIXED
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_RELEASE."`) LIKE LOWER('%fix%') AND `".$COL_STATUS."` LIKE '0';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    if ($count > 0) {
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD."FIXES: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
    }

    # NUKED
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` LIKE '1';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    if ($count > 0) {
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD.RED."NUKED: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
    }

    # UNNUKED
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` LIKE '2';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    if ($count > 0) {
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD.GREEN."UNNUKED: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
    }

    # DELETED
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` LIKE '3';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    if ($count > 0) {
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD.RED."DELETED: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
    }

    # UNDELETED
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` LIKE '4';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    if ($count > 0) {
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD.GREEN."UNDELETED: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
    }

    # STATS BY TIME PERIOD
    my $now = time();
    # TODAY
    my $period = $now - 86400;
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_PRETIME."` >= '".$period."' AND `".$COL_PRETIME."` <= '".$now."';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
    $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
    $self->sendMessage($nick, BOLD."RLS TODAY: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

    # WEEK
    $period = $now - 604800;
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_PRETIME."` >= '".$period."' AND `".$COL_PRETIME."` <= '".$now."';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
    $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
    $self->sendMessage($nick, BOLD."WEEK: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

    # MONTH
    $period = $now - 2628000;
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_PRETIME."` >= '".$period."' AND `".$COL_PRETIME."` <= '".$now."';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
    $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
    $self->sendMessage($nick, BOLD."MONTH: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

    # YEAR
    $period = $now - 31536000;
    $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_PRETIME."` >= '".$period."' AND `".$COL_PRETIME."` <= '".$now."';");
    $query->execute() or die $dbh->errstr;
    ($count, $files, $size) = $query->fetchrow();
    $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
    $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
    $self->sendMessage($nick, BOLD."YEAR: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

    # FIRST RELEASE
    $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM `".$DB_TABLE."` ORDER BY `".$COL_PRETIME."` ASC LIMIT 1;");
    $query->execute() or die $dbh->errstr;

        # Set variables
        my ($id, $pretime, $pre, $section, $file, $sizes, $status, $reason, $group) = $query->fetchrow();
        $pretime = $self->get_time_since($pretime);
        $section = $self->getSection($section);
        $sizes = $self->getSize($sizes);

        # SECTION + RELEASE
        my $result = $section." ".$pre." ".$pretime;

        # FILES + SIZE?
        if ($file > 0 or $sizes > 0.00) {
            $result .= GREY." - [".NORMAL.$file.ORANGE."F".NORMAL." - ".$sizes.GREY."] ".NORMAL;
        }

        # NUKED or DEL?
        if ($status eq 1 or $status eq 3) {
            $status = $self->getType($status);
            $result .= " - ".$status.RED.": ".$reason;
        }

        # Return result
        #$self->sendMessage($nick, BOLD.GREEN."FIRST PRE: ".NORMAL.$result);

    # LAST RELEASE
    $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM `".$DB_TABLE."` ORDER BY `".$COL_PRETIME."` DESC LIMIT 1;");
    $query->execute() or die $dbh->errstr;

        # Set variables
        ($id, $pretime, $pre, $section, $file, $sizes, $status, $reason, $group) = $query->fetchrow();
        $pretime = $self->get_time_since($pretime);
        $section = $self->getSection($section);
        $sizes = $self->getSize($sizes);

        # SECTION + RELEASE
        $result = $section." ".$pre." ".$pretime;

        # FILES + SIZE?
        if ($file > 0 or $sizes > 0.00) {
            $result .= GREY." - [".NORMAL.$file.ORANGE."F".NORMAL." - ".$sizes.GREY."] ".NORMAL;
        }

        # NUKED or DEL?
        if ($status eq 1 or $status eq 3) {
            $status = $self->getType($status);
            $result .= " - ".$status.RED.": ".$reason;
        }

        # Return result
        $self->sendMessage($nick, BOLD.GREEN."LAST PRE: ".NORMAL.$result);

    # FIRST NUKE
    $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` = '1' ORDER BY `".$COL_PRETIME."` ASC LIMIT 1;");
    $query->execute() or die $dbh->errstr;

        # Set variables
        ($id, $pretime, $pre, $section, $file, $sizes, $status, $reason, $group) = $query->fetchrow();
        $pretime = $self->get_time_since($pretime);
        $section = $self->getSection($section);
        $sizes = $self->getSize($sizes);

        # SECTION + RELEASE
        $result = $section." ".$pre." ".$pretime;

        # FILES + SIZE?
        if ($file > 0 or $sizes > 0.00) {
            $result .= GREY." - [".NORMAL.$file.ORANGE."F".NORMAL." - ".$sizes.GREY."] ".NORMAL;
        }

        # NUKED or DEL?
        if ($status eq 1 or $status eq 3) {
            $status = $self->getType($status);
            $result .= " - ".$status.RED.": ".$reason;
        }

        # Return result
        $self->sendMessage($nick, BOLD.RED."FIRST NUKE: ".NORMAL.$result);

    # LAST NUKE
    $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` = '1' ORDER BY `".$COL_PRETIME."` DESC LIMIT 1;");
    $query->execute() or die $dbh->errstr;

        # Set variables
        ($id, $pretime, $pre, $section, $file, $sizes, $status, $reason, $group) = $query->fetchrow();
        $pretime = $self->get_time_since($pretime);
        $section = $self->getSection($section);
        $sizes = $self->getSize($sizes);

        # SECTION + RELEASE
        $result = $section." ".$pre." ".$pretime;

        # FILES + SIZE?
        if ($file > 0 or $sizes > 0.00) {
            $result .= GREY." - [".NORMAL.$file.ORANGE."F".NORMAL." - ".$sizes.GREY."] ".NORMAL;
        }

        # NUKED or DEL?
        if ($status eq 1 or $status eq 3) {
            $status = $self->getType($status);
            $result .= " - ".$status.RED.": ".$reason;
        }

        # Return result
        $self->sendMessage($nick, BOLD.RED."LAST NUKE: ".NORMAL.$result);

    $self->sendMessage($nick, "No more stats for ".ORANGE."PreDB".NORMAL);

    # Finish query
    $query->finish();

    # Disconnect Database
    $dbh->disconnect();
}

# Return stats of given time period: day, week, month, year
# Param (nick, period)
sub periodStats {
    my $self = shift;
    my ($nick, $period) = @_;
    my $diff;
    my $now = time();

    # Get time period
    if ($period ~~ m/!day|!today/i) {
        $diff = $now - 86400;
        $period = "Today's";
    } elsif ($period eq "!week") {
        $diff = $now - 604800;
        $period = "Weekly";
    } elsif ($period eq "!month") {
        $diff = $now - 2628000;
        $period = "Monthly";
    } elsif ($period eq "!year") {
        $diff = $now - 31536000;
        $period = "Yearly";
    }

    # Connect to Database
    my $dbh = DBI->connect("DBI:mysql:database=$DB_NAME;host=$DB_HOST", $DB_USER, $DB_PASSWD)
        or die "Couldn't connect to database: " . DBI->errstr;

    # Prepare Query -> Get stats by time period
    my $query = $dbh->prepare("
        SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` = '0' AND `".$COL_PRETIME."` >= '".$diff."' AND `".$COL_PRETIME."` <= '".$now."'
        UNION
        SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` = '1' AND `".$COL_PRETIME."` >= '".$diff."' AND `".$COL_PRETIME."` <= '".$now."'
        UNION
        SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` = '2' AND `".$COL_PRETIME."` >= '".$diff."' AND `".$COL_PRETIME."` <= '".$now."'
        UNION
        SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` = '3' AND `".$COL_PRETIME."` >= '".$diff."' AND `".$COL_PRETIME."` <= '".$now."'
        UNION
        SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE `".$COL_STATUS."` = '4' AND `".$COL_PRETIME."` >= '".$diff."' AND `".$COL_PRETIME."` <= '".$now."';");

    # Execute Query
    $query->execute() or die $dbh->errstr;

    # Get rows
    my $rows = $query->rows();
    # Do we have results?
    if ($rows > 0) {
        $self->sendMessage($nick, BOLD.$period.NORMAL." stats");

        # PRE
        my ($count, $files, $size) = $query->fetchrow();
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, GREEN.BOLD."PRE: ".NORMAL.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

        # NUKE
        ($count, $files, $size) = $query->fetchrow();
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, RED.BOLD."NUKE: ".NORMAL.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

        # UNNUKE
        ($count, $files, $size) = $query->fetchrow();
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, ORANGE.BOLD."UNNUKE: ".NORMAL.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

        # UNNUKE
        ($count, $files, $size) = $query->fetchrow();
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, RED.BOLD."DEL: ".NORMAL.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

        # UNNUKE
        ($count, $files, $size) = $query->fetchrow();
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, ORANGE.BOLD."UNDEL: ".NORMAL.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

    } else  {
        $self->sendMessage($nick, BOLD."Sorry!".NORMAL." Found no ".UNDERLINE.$period.NORMAL." stats.");
    }

    # Finish query
    $query->finish();

    # Disconnect Database
    $dbh->disconnect();
}

# Return group stats
# Param (nick, group)
sub groupStats {
    my $self = shift;
    my ($nick, $param) = @_;

    # Connect to Database
    my $dbh = DBI->connect("DBI:mysql:database=$DB_NAME;host=$DB_HOST", $DB_USER, $DB_PASSWD)
        or die "Couldn't connect to database: " . DBI->errstr;

    # ALL RELEASES (FILES - SIZE)
    my $query = $dbh->prepare("SELECT `".$COL_GROUP."`, COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? );");
    $query->execute($param) or die $dbh->errstr;

    # Get rows
    my $rows = $query->rows();

    # Get results
    my ($group, $count, $files, $size) = $query->fetchrow();

    # set some stats variables
    my $releases = $count;  # set number of all rls
    my $fine = 0;           # number for fine rls
    my $nuked = 0;          # number for nuked rls

    if ($rows > 0) {
        $self->sendMessage($nick, "Groupstats for '".ORANGE.$group.NORMAL."'");

        # ALL RLS
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD."PRED: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

        # FINE
        $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_STATUS."` = '0';");
        $query->execute($param) or die $dbh->errstr;
        ($count, $files, $size) = $query->fetchrow();
        $fine = $count; # set number of fine releases
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD."FINE: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

        # IF NOT ALL RELEASES ARE FINE
        if ($releases != $fine) {
            # PROPER
            $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND LOWER(`".$COL_RELEASE."`) LIKE LOWER('%proper%') AND `".$COL_STATUS."` LIKE '0';");
            $query->execute($param) or die $dbh->errstr;
            ($count, $files, $size) = $query->fetchrow();
            if ($count > 0) {
                ($count, $files, $size) = $query->fetchrow();
                $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
                $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
                $self->sendMessage($nick, BOLD."PROPER: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
            }

            # INTERNAL
            $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND LOWER(`".$COL_RELEASE."`) LIKE LOWER('%internal%') AND `".$COL_STATUS."` LIKE '0';");
            $query->execute($param) or die $dbh->errstr;
            ($count, $files, $size) = $query->fetchrow();
            if ($count > 0) {
                ($count, $files, $size) = $query->fetchrow();
                $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
                $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
                $self->sendMessage($nick, BOLD."INTERNALS: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
            }

            # REPACKS
            $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND LOWER(`".$COL_RELEASE."`) LIKE LOWER('%repack%') AND `".$COL_STATUS."` LIKE '0';");
            $query->execute($param) or die $dbh->errstr;
            ($count, $files, $size) = $query->fetchrow();
            if ($count > 0) {
                ($count, $files, $size) = $query->fetchrow();
                $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
                $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
                $self->sendMessage($nick, BOLD."REPACKS: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
            }

            # FIXED
            $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND LOWER(`".$COL_RELEASE."`) LIKE LOWER('%fix%') AND `".$COL_STATUS."` LIKE '0';");
            $query->execute($param) or die $dbh->errstr;
            ($count, $files, $size) = $query->fetchrow();
            if ($count > 0) {
                $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
                $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
                $self->sendMessage($nick, BOLD."FIXES: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
            }

            # NUKED
            $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_STATUS."` LIKE '1';");
            $query->execute($param) or die $dbh->errstr;
            ($count, $files, $size) = $query->fetchrow();
            if ($count > 0) {
                $nuked = $count; # set number of nukes
                $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
                $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
                $self->sendMessage($nick, BOLD.RED."NUKED: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
            }

            # UNNUKED
            $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_STATUS."` LIKE '2';");
            $query->execute($param) or die $dbh->errstr;
            ($count, $files, $size) = $query->fetchrow();
            if ($count > 0) {
                $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
                $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
                $self->sendMessage($nick, BOLD.GREEN."UNNUKED: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
            }

            # DELETED
            $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_STATUS."` LIKE '3';");
            $query->execute($param) or die $dbh->errstr;
            ($count, $files, $size) = $query->fetchrow();
            if ($count > 0) {
                $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
                $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
                $self->sendMessage($nick, BOLD.RED."DELETED: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
            }

            # UNDELETED
            $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_STATUS."` LIKE '4';");
            $query->execute($param) or die $dbh->errstr;
            ($count, $files, $size) = $query->fetchrow();
            if ($count > 0) {
                $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
                $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
                $self->sendMessage($nick, BOLD.GREEN."UNDELETED: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");
            }
        }

        # STATS BY TIME PERIOD
        my $now = time();
        # TODAY
        my $period = $now - 86400;
        $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_PRETIME."` >= '".$period."' AND `".$COL_PRETIME."` <= '".$now."';");
        $query->execute($param) or die $dbh->errstr;
        ($count, $files, $size) = $query->fetchrow();
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD."RLS TODAY: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

        # WEEK
        $period = $now - 604800;
        $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_PRETIME."` >= '".$period."' AND `".$COL_PRETIME."` <= '".$now."';");
        $query->execute($param) or die $dbh->errstr;
        ($count, $files, $size) = $query->fetchrow();
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD."WEEK: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

        # MONTH
        $period = $now - 2628000;
        $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_PRETIME."` >= '".$period."' AND `".$COL_PRETIME."` <= '".$now."';");
        $query->execute($param) or die $dbh->errstr;
        ($count, $files, $size) = $query->fetchrow();
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD."MONTH: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

        # YEAR
        $period = $now - 31536000;
        $query = $dbh->prepare("SELECT COUNT(*), SUM(`".$COL_FILES."`), SUM(`".$COL_SIZE."`) FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_PRETIME."` >= '".$period."' AND `".$COL_PRETIME."` <= '".$now."';");
        $query->execute($param) or die $dbh->errstr;
        ($count, $files, $size) = $query->fetchrow();
        $size = (defined $size and $size > 0) ? $self->getSize($size) : "0".ORANGE."MB";
        $files = defined $files ? $files.ORANGE."F" : "0".ORANGE."F";
        $self->sendMessage($nick, BOLD."YEAR: ".NORMAL.ORANGE.$count.GREY." (".NORMAL.$files.GREY." / ".NORMAL.$size.GREY.")");

        # FIRST RELEASE
        $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) ORDER BY `".$COL_PRETIME."` ASC LIMIT 1;");
        $query->execute($param) or die $dbh->errstr;

            # Set variables
            my ($id, $pretime, $pre, $section, $file, $sizes, $status, $reason, $group) = $query->fetchrow();
            $pretime = $self->get_time_since($pretime);
            $section = $self->getSection($section);
            $sizes = $self->getSize($sizes);

            # SECTION + RELEASE
            my $result = $section." ".$pre." ".$pretime;

            # FILES + SIZE?
            if ($file > 0 or $sizes > 0.00) {
                $result .= GREY." - [".NORMAL.$file.ORANGE."F".NORMAL." - ".$sizes.GREY."] ".NORMAL;
            }

            # NUKED or DEL?
            if ($status eq 1 or $status eq 3) {
                $status = $self->getType($status);
                $result .= " - ".$status.RED.": ".$reason;
            }

            # Return result
            $self->sendMessage($nick, BOLD.GREEN."FIRST PRE: ".NORMAL.$result);

        # LAST RELEASE
        $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) ORDER BY `".$COL_PRETIME."` DESC LIMIT 1;");
        $query->execute($param) or die $dbh->errstr;

            # Set variables
            ($id, $pretime, $pre, $section, $file, $sizes, $status, $reason, $group) = $query->fetchrow();
            $pretime = $self->get_time_since($pretime);
            $section = $self->getSection($section);
            $sizes = $self->getSize($sizes);

            # SECTION + RELEASE
            $result = $section." ".$pre." ".$pretime;

            # FILES + SIZE?
            if ($file > 0 or $sizes > 0.00) {
                $result .= GREY." - [".NORMAL.$file.ORANGE."F".NORMAL." - ".$sizes.GREY."] ".NORMAL;
            }

            # NUKED or DEL?
            if ($status eq 1 or $status eq 3) {
                $status = $self->getType($status);
                $result .= " - ".$status.RED.": ".$reason;
            }

            # Return result
            $self->sendMessage($nick, BOLD.GREEN."LAST PRE: ".NORMAL.$result);

        if ($nuked > 0) {
            # FIRST NUKE
            $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_STATUS."` = '1' ORDER BY `".$COL_PRETIME."` ASC LIMIT 1;");
            $query->execute($param) or die $dbh->errstr;

                # Set variables
                ($id, $pretime, $pre, $section, $file, $sizes, $status, $reason, $group) = $query->fetchrow();
                $pretime = $self->get_time_since($pretime);
                $section = $self->getSection($section);
                $sizes = $self->getSize($sizes);

                # SECTION + RELEASE
                $result = $section." ".$pre." ".$pretime;

                # FILES + SIZE?
                if ($file > 0 or $sizes > 0.00) {
                    $result .= GREY." - [".NORMAL.$file.ORANGE."F".NORMAL." - ".$sizes.GREY."] ".NORMAL;
                }

                # NUKED or DEL?
                if ($status eq 1 or $status eq 3) {
                    $status = $self->getType($status);
                    $result .= " - ".$status.RED.": ".$reason;
                }

                # Return result
                $self->sendMessage($nick, BOLD.RED."FIRST NUKE: ".NORMAL.$result);

            # LAST NUKE
            $query = $dbh->prepare("SELECT id,ctime,rlsname,section,files,size,status,nukereason,grp FROM `".$DB_TABLE."` WHERE LOWER(`".$COL_GROUP."`) LIKE LOWER( ? ) AND `".$COL_STATUS."` = '1' ORDER BY `".$COL_PRETIME."` DESC LIMIT 1;");
            $query->execute($param) or die $dbh->errstr;

                # Set variables
                ($id, $pretime, $pre, $section, $file, $sizes, $status, $reason, $group) = $query->fetchrow();
                $pretime = $self->get_time_since($pretime);
                $section = $self->getSection($section);
                $sizes = $self->getSize($sizes);

                # SECTION + RELEASE
                $result = $section." ".$pre." ".$pretime;

                # FILES + SIZE?
                if ($file > 0 or $sizes > 0.00) {
                    $result .= GREY." - [".NORMAL.$file.ORANGE."F".NORMAL." - ".$sizes.GREY."] ".NORMAL;
                }

                # NUKED or DEL?
                if ($status eq 1 or $status eq 3) {
                    $status = $self->getType($status);
                    $result .= " - ".$status.RED.": ".$reason;
                }

                # Return result
                $self->sendMessage($nick, BOLD.RED."LAST NUKE: ".NORMAL.$result);
        }
    } else  {
        $self->sendMessage($nick, BOLD."Sorry!".NORMAL." Found no stats for ".UNDERLINE.$param.NORMAL.".");
    }

    $self->sendMessage($nick, "No more stats for '".ORANGE.$group.NORMAL."'");

    # Finish query
    $query->finish();

    # Disconnect Database
    $dbh->disconnect();
}

##
# Basic functions
##

# Return the type with a color
# Param (type)
sub getType {
    my $self = shift;
    my $type = $_[0];
    my $color;

    # PRE
    if ($type ~~ m/0|2|4/) {
        $color .= GREEN."PRE";
    # UNNUKE / UNDELPRE / INFO
    } elsif ($type eq 1) {
        $color .= RED."NUKED";
    # NUKE / DELPRE
    } elsif ($type eq 3) {
        $color .= RED."DEL";
    }

    return $color.NORMAL;
}

# Formats the size to a smaller String.
# Param (size)
sub getSize {
    my $self = shift;
    my $size = $_[0];

    # format the size
    if ($size >= 1073741824) {
        $size = sprintf "%.2f", ($size / 1073741824);
        return $size.ORANGE."PB".NORMAL;
    } elsif ($size >= 1048576) {
        $size = sprintf "%.2f", ($size / 1048576);
        return $size.ORANGE."TB".NORMAL;
    } elsif ($size > 1024) {
        $size = sprintf "%.2f", ($size / 1024);
        return $size.ORANGE."GB".NORMAL;
    } elsif ($size < 1 and $size > 0) {
        $size = sprintf "%.2f", ($size * 1024);
        return $size.ORANGE."KB".NORMAL;
    } else {
        return $size.ORANGE."MB".NORMAL;
    }
}

# Return the section with a color
# Param (section)
sub getSection  {
    my $self = shift;
    my $section = $_[0];
    my $color;

    # XXX
    if($section ~~ m/xxx|ima?ge?set/i) {
        $color = PINK;

    # TV Shows/Series: TV TV-BLURAY TV-DVDR TV-DVDRiP TV-HR TV-x264 TV-XViD
    } elsif ($section ~~ m/tv-?|doku/i) {
        $color = ORANGE;

    # Movies: DVDR / XVID / X264 / SVCD / VCD / BLURAY
    } elsif ($section ~~ m/dvdr|xvid|x264|vcd|divx|bluray/i) {
        $color = RED;

    # Console Games: NDS PS1 PS2 PS3 PS4 PSP PSX PSXPSP GAMECUBE GAMEBOY
    } elsif ($section ~~ m/ps[\dpx]|xbox|ngc|nds|gcn|wii|game(cube|boy)/i) {
        $color = TEAL;

    # Music Videos: MVID / MDVDR
    } elsif ($section ~~ m/mdvdr|mvid/i) {
        $color = LIGHT_BLUE;

    # Audio: MP3 / SAMPLE
    } elsif ($section ~~ m/mp3|sample|flac/i) {
        $color = LIGHT_GREEN;

    # ANIME
    } elsif ($section ~~ m/anime/i) {
        $color = PURPLE;

    # Books: EBOOK / AUDIOBOOK
    } elsif ($section ~~ m/[e|a].*book/i) {
        $color = GREEN;

    # PRE DOX PDA SUBPACK COVER
    } elsif ($section ~~ m/dox|pda|subpack|cover|font/i) {
        $color = LIGHT_CYAN;

    # APPS 0DAY MOBILE
    } elsif ($section ~~ m/apps|0day|mobile/i) {
        $color = BROWN;

    # GAMES
    } elsif ($section ~~ m/games/i) {
        $color = BLUE;

    # UNKOWN
    } else {
        $color = GREY;
    }

    return GREY."[".BOLD.$color.$section.NORMAL.GREY."]".NORMAL;
}

# Return time passed since a timestamp
# 1y 2m 27d 4h 5m 57s
# Param (timestamp)
sub get_time_since {
    my $self = shift;
    my $secs = time() - $_[0];
    my $time;

    # Set variables
    # YEARS
    if ($secs >= 31536000) {
        $time .= BOLD.int($secs / 31536000).NORMAL.GREY."y ";
        $secs = $secs % 31536000;
    }
    # MONTHS
    if ($secs >= 2628000) {
        $time .= BOLD.int($secs / 2628000).NORMAL.GREY."m ";
        $secs = $secs % 2628000;
    }
    # DAYS
    if ($secs >= 86400) {
        $time .= BOLD.int($secs / 86400).NORMAL.GREY."d ";
        $secs = $secs % 86400;
    }
    # HOURS
    if ($secs >= 3600) {
        $time .= BOLD.int($secs / 3600).NORMAL.GREY."h ";
        $secs = $secs % 3600;
    }
    # MINUTES
    if ($secs >= 60) {
        $time .= BOLD.int($secs / 60).NORMAL.GREY."m ";
        $secs = $secs % 60;
    }
    # SECONDS
    if ($secs >= 0) {
        $time .= BOLD.$secs.NORMAL.GREY."s";
    }

    return "- ".GREY."pred ".$time." ago".NORMAL;
}

# Return known commands
# Param (nick)
sub searchHelp {
    my $self = shift;
    my $nick = $_[0];

    # send known commands
    $self->sendMessage($nick, ORANGE.BOLD."Known commands:".NORMAL);
    # !pre release
    $self->sendMessage($nick, ORANGE.BOLD."!pre".NORMAL.LIGHT_BLUE." release.name-group ".GREY."//".NORMAL." Search for specific release");
    # !dupe release
    $self->sendMessage($nick, ORANGE.BOLD."!dupe".NORMAL.LIGHT_BLUE." bla bla bla ".GREY."//".NORMAL." Search for dupes");
    # !grp group (section)
    $self->sendMessage($nick, ORANGE.BOLD."!grp".NORMAL.", ".ORANGE.BOLD."!group".NORMAL.LIGHT_BLUE." group ".TEAL."(section) ".GREY."//".NORMAL." Last 10 group releases (by section)");
    # !new section
    $self->sendMessage($nick, ORANGE.BOLD."!new".NORMAL.LIGHT_BLUE." section ".GREY."//".NORMAL." Last 10 section releases");
    # !nukes (group/section -g/-s)
    $self->sendMessage($nick, ORANGE.BOLD."!nukes".NORMAL.TEAL." (group/section -g/-s) ".GREY."//".NORMAL." Last 10 nukes (by group/by section)");
    # !top
    $self->sendMessage($nick, ORANGE.BOLD."!top ".NORMAL.GREY."//".NORMAL." All-time Top 10 groups");
    # !top section
    $self->sendMessage($nick, ORANGE.BOLD."!top".NORMAL.LIGHT_BLUE." section ".GREY."//".NORMAL." Top 5 groups of a section");
    # !day, !today, !week, !month, !year
    $self->sendMessage($nick, ORANGE.BOLD."!day".NORMAL.", ".ORANGE.BOLD."!today".NORMAL.", ".ORANGE.BOLD."!week".NORMAL.", ".ORANGE.BOLD."!month".NORMAL.", ".ORANGE.BOLD."!year ".NORMAL.GREY."//".NORMAL." Stats for a specific time period");
    # !stats
    $self->sendMessage($nick, ORANGE.BOLD."!stats ".NORMAL.GREY."//".NORMAL." Extended PreDB stats");
    # !stats group
    $self->sendMessage($nick, ORANGE.BOLD."!stats".NORMAL.LIGHT_BLUE." group ".GREY."//".NORMAL." Group stats");
    # !db
    $self->sendMessage($nick, ORANGE.BOLD."!db ".NORMAL.GREY."//".NORMAL." Short PreDB stats");
    # !help/!cmds
    $self->sendMessage($nick, ORANGE.BOLD."!help".NORMAL.", ".ORANGE.BOLD."!cmds ".NORMAL.GREY."//".NORMAL."Known commands");
    # Color explanation
    $self->sendMessage($nick, ORANGE.BOLD."Orange:".NORMAL." command ".GREY."//".LIGHT_BLUE.BOLD." Blue: ".NORMAL."needed Parameter ".GREY."//".TEAL.BOLD." Teal:".NORMAL." optional parameter");
}

##
# IRC functions
##

# Send IRC message
# Param (nick, message)
sub sendMessage {
    my $self = shift;
    my ($nick, $message) = @_;

    # Brackets before and after the message
    $message = GREY."< ".NORMAL.$message.GREY." >".NORMAL;

    # send private message
    $self->PutIRC("PRIVMSG ".$nick." : ".$message);
}



1;
