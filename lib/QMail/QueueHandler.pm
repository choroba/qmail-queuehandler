package Qmail::QueueHandler;

# Qmail::QueueHander
#
# Copyright (c) 2016 Dave Cross <dave@perlhacks.com>
# Based on original version by Michele Beltrame <mb@italpro.net>
#
# This program is distributed under the GNU GPL.
# For more information have a look at http://www.gnu.org

use Moose;

use Term::ANSIColor;
use Getopt::Std;
use File::Basename;

my $version = '2.0.0 [alpha]';
my $me = basename $0;

#################### USER CONFIGURATION BEGIN ####################

#####
# Set this to your qmail queue directory (be sure to include the final slash!)
my $bigtodo = (-d "${queue}todo/0") ? 0 : 1; # 1 means no big-todo

has queue => (
  is => 'ro',
  isa => 'Str',
  default => '/var/qmail/queue/',
);

has bigtodo => (
  is => 'ro',
  isa => 'Bool',
  default => sub { -d $_->[0]->queue . 'todo/0' },
);

#####
# If your system has got automated command to start/stop qmail, then
# enter them here.
# ### Be sure to uncomment only ONE of each variable declarations ###

# For instance, this is if you have DJB's daemontools
#my $stopqmail = '/usr/local/bin/svc -d /service/qmail-deliver';
#my $startqmail = '/usr/local/bin/svc -u /service/qmail-deliver';

# While this is if you have a Debian GNU/Linux with its qmail package
#my $stopqmail = '/etc/init.d/qmail stop';
#my $startqmail = '/etc/init.d/qmail start';

# If you don't have scripts, leave $stopqmail blank (the process will
# be hunted and killed by qmHandle):
#my $stopqmail = '';

# However, you still need to launch qmail in a way or the other. So,
# if you have a standard qmail 1.03 use this:
#my $startqmail = "csh -cf '/var/qmail/rc &'";

# While, if you have a standard qmail < 1.03 you should use this:
#my $startqmail = '/var/qmail/bin/qmail-start ./Mailbox splogger qmail &';

has commands => (
  is => 'ro',
  isa => HashRef,
  default => sub { {
    start => 'service qmail start',
    stop  => 'service qmail stop',
    pid   => 'pidof qmail-send',
  } },
);

has colours => (
  is => 'ro',
  isa => 'HashRef',
  default => sub { {
    msg => '',
    stat => '',
    end => '',
  } },
);

has summary => (
  is => 'ro',
  isa => 'Bool',
);

has deletions => (
  is => 'ro',
  isa => 'Bool',
);

has action => (
  is => 'ro',
  isa => 'ArrayRef',
  default => sub { [] },
);

####################  USER CONFIGURATION END  ####################

# Print usage if no arguments
@ARGV or usage();

# Get command line options

my ($cmsg, $cstat, $cend) = ('', '', '');
my @colours = (
    color('bold bright_blue'),
    color('bold bright_red'),
    color('reset'),
);

my $actions = parse_args(@ARGV);

# Set "global" variables
my $restart;
my @todel = ();
my @toflag = ();

# Create a hash of messages in queue and the type of recipients they have
# and whether they are bouncing.

my $msglist = analyse_msgs($queue);

# If we want to delete stuff, then stop qmail.
if ($dactions) {
    $restart = stop_qmail();
}

# Execute actions    
foreach my $action (@$actions) {
   my $sub = shift @$action; # First element is the sub
   $sub->(@$action);         # Others the arguments, if any
}

# If we have planned deletions, then do them.
if ($dactions) {
    trash_msgs();
}

# If we stopped qmail, then restart it
$restart and start_qmail();


# ##### SERVICE FUNCTIONS #####

sub analyse_msgs {
    my ($queue) = @_;

    my (%msglist, %todohash, %bouncehash);

    opendir(my $messdir,"${queue}mess");
    my (@dirlist) = grep { !/\./ } readdir $messdir;
    closedir $messdir;

    opendir(my $tododir,"${queue}todo");
    my (@todolist) = grep { !/\./ } readdir $tododir;
    closedir $tododir;

    if ($bigtodo) {
        foreach my $todofile (@todolist) {
            $todohash{$todofile} = $todofile;
        }
    } else {
        foreach my $tododir (@todolist) {
            opendir (my $subdir,"${queue}todo/$tododir");
            my (@todofiles) = grep { !/\./ }
                              map  { "$tododir/$_" } readdir $subdir;
            foreach my $todofile (@todofiles) {
                $msglist{ $todofile }{ 'todo' } = $todofile;
            }
        }
    }

    opendir(my $bouncedir,"${queue}bounce");
    my (@bouncelist) = grep { !/\./ } readdir $bouncedir;
    closedir $bouncedir;

    foreach my $bouncefile (@bouncelist) {
        $bouncehash{$bouncefile} = 'B';
    }

    foreach my $dir (@dirlist) {
        opendir (my $subdir,"${queue}mess/$dir");
        my (@files) = grep { !/\./ }
                      map  { "$dir/$_" } readdir $subdir;

        opendir (my $infosubdir,"${queue}info/$dir");
        my (@infofiles) = grep { !/\./ }
                          map  { "$dir/$_" } readdir $infosubdir;

        opendir (my $localsubdir,"${queue}local/$dir");
        my (@localfiles) = grep { !/\./ }
                           map  { "$dir/$_" } readdir $localsubdir;

        opendir (my $remotesubdir,"${queue}remote/$dir");
        my (@remotefiles) = grep { !/\./ }
                            map  { "$dir/$_" } readdir $remotesubdir;

        foreach my $infofile (@infofiles) {
            $msglist{$infofile}{sender} = 'S';
        }

        foreach my $localfile (@localfiles) {
            $msglist{$localfile}{local} = 'L';
        }

        foreach my $remotefile (@remotefiles) {
            $msglist{$remotefile}{remote} = 'R';
        }

        foreach my $file (@files) {
            my ($dirno, $msgno) = split(/\//, $file);
            if ($bouncehash{$msgno}) {
                $msglist{ $file }{bounce} = 'B';
            }
            if ($bigtodo == 1) {
                if ($todohash{$msgno}) {
                    $msglist{ $file }{todo} = "$msgno";
                }
            }
        }

        closedir $subdir;
        closedir $infosubdir;
        closedir $localsubdir;
        closedir $remotesubdir;
    }

    return \%msglist;
}

sub parse_args {
    my @args = @_;
    my @actions;
    my %opt;

    getopts('alLRNcsm:f:F:d:S:h:b:H:B:t:DV', \%opt);

    foreach my $opt (keys %opt) {
        SWITCH: {
            $opt eq 'a' and do {
                push @actions, [\&send_msgs];
                last SWITCH;
            };
            $opt eq 'l' and do {
                push @actions, [\&list_msg, 'A'];
                last SWITCH;
            };
            $opt eq 'L' and do {
                push @actions, [\&list_msg, 'L'];
                last SWITCH;
            };
            $opt eq 'R' and do {
                push @actions, [\&list_msg, 'R'];
                last SWITCH;
            };
            $opt eq 'N' and do {
                $summary = 1;
                last SWITCH;
            };
            $opt eq 'c' and do {
                ($cmsg, $cstat, $cend) = @colours;
                last SWITCH;
            };
            $opt eq 's' and do {
                push @actions, [\&stats];
                last SWITCH;
            };
            $opt eq 'm' and do {
                push @actions, [\&view_msg, $opt{$opt}];
                last SWITCH;
            };
            $opt eq 'f' and do {
                push @actions, [\&del_msg_from_sender, $opt{$opt}];
                $dactions++;
                last SWITCH;
            };
            $opt eq 'F' and do {
                push @actions, [\&del_msg_from_sender_r, $opt{$opt}];
                $dactions++;
                last SWITCH;
            };
            $opt eq 'd' and do {
                push @actions, [\&del_msg, $opt{$opt}];
                $dactions++;
                last SWITCH;
            };
            $opt eq 'S' and do {
                push @actions, [\&del_msg_subj, $opt{$opt}];
                $dactions++;
                last SWITCH;
            };
            $opt eq 'h' and do {
                push @actions, [\&del_msg_header_r, 'I', $opt{$opt}];
                $dactions++;
                last SWITCH;
            };
            $opt eq 'b' and do {
                push @actions, [\&del_msg_body_r, 'I', $opt{$opt}];
                $dactions++;
                last SWITCH;
            };
            $opt eq 'H' and do {
                push @actions, [\&del_msg_header_r, 'C', $opt{$opt}];
                $dactions++;
                last SWITCH;
                };
            $opt eq 'B' and do {
                push @actions, [\&del_msg_body_r, 'C', $opt{$opt}];
                $dactions++;
                last SWITCH;
            };
            $opt eq 't' and do {
                push @actions, [\&flag_remote, $opt{$opt}];
                last SWITCH;
            };
            $opt eq '-D' and do {
                push @actions, [\&del_all];
                $dactions++;
                last SWITCH; };
            $opt eq '-V' and do {
                push @actions, [\&version];
                last SWITCH;
                };
            usage();
        }
    }

    return \@actions;
}

# Stop qmail
sub stop_qmail {

    # If qmail is running, we stop it
    if (my $qmpid = qmail_pid()) {

        # If there is a system script available, we use it
        if ($stopqmail ne '') {

            warn "Calling system script to terminate qmail...\n";
            if (system($stopqmail) > 0) {
                die 'Could not stop qmail';
            }
            sleep 1 while qmail_pid();

        # Otherwise, we're killers!
        } else {
            warn "Terminating qmail (pid $qmpid)... ",
                 "this might take a while if qmail is working.\n";
            kill 'TERM', $qmpid;
    
            sleep 1 while qmail_pid();
        }

    # If it isn't, we don't. We also return a false value so our caller
    # knows they might not want to restart it later.
    } else {
        warn "Qmail isn't running... no need to stop it.\n";
        return 0;
    }

    return 1;
}

# Start qmail
sub start_qmail {

    # If qmail is running, why restart it?
    if (my $qmpid = qmail_pid()) {
        warn "Qmail is already running again, so it won't be restarted.\n";
        return 1;
    }

    # In any other case, we restart it
    warn "Restarting qmail... ";
    system($startqmail);
    warn "done (hopefully).\n";

    return 1;
}

# Returns the subject of a message
sub get_subject {
    my $msg = shift;
    my $msgsub;
    open (my $msg_fh, '<', "${queue}mess/$msg")
        or die("cannot open message $msg! Is qmail-send running?\n");
    while (<$msg_fh>) {
        if ( /^Subject: (.*)/) {
            $msgsub = $1;
            chomp $msgsub;
        } elsif ( $_ eq "\n") {
            last;
        }
    }
    close ($msg_fh);
    return $msgsub;
}

sub get_sender {
    my $msg = shift;

    open (my $msg_fh, '<', "${queue}/info/$msg")
        or die("cannot open info file ${queue}/info/$msg! ",
               "Is qmail-send running?\n");
    my $sender = <$msg_fh>;
    substr($sender, 0, 1) = '';
    chomp $sender;
    close ($msg_fh);
    return $sender;
}


# ##### MAIN FUNCTIONS #####

# Tries to send all queued messages now 
# This is achieved by sending an ALRM signal to qmail-send
sub send_msgs {

    # If qmail is running, we force sending of messages
    if (my $qmpid = qmail_pid()) {

        kill 'ALRM', $qmpid;

    } else {

        warn "Qmail isn't running, can't send messages!\n";

    }
    return;
}

sub show_msg_info {
    my $msg_id = shift;
    my %msg;

    open (my $info_fh, '<', "${queue}info/$msg_id");
    $msg{ret} = <$info_fh>;
    substr($msg{ret}, 0, 1) = '';
    chomp $msg{ret};
    close ($info_fh);
    my ($dirno, $rmsg) = split(/\//, $msg_id);
    print "$rmsg ($dirno, $msg_id)\n";
 
    # Get message (file) size
    $msg{fsize} = (stat("${queue}mess/$msg_id"))[7];

    my %header = (
        Date    => 'date',
        From    => 'from',
        Subject => 'subject',
        To      => 'to',
        Cc      => 'cc',
    );

    # Read something from message header (sender, receiver, subject, date)
    open (my $msg_fh, '<', "${queue}mess/$msg_id");
    while (<$msg_fh>) {
        chomp;
        foreach my $h (keys %header) {
            if (/^$h: (.*)/) {
                $msg{$header{$h}} = $1;
                last;
            }
        }
    }
    close($msg_fh);

    # Add "pseudo-headers" for output
    $header{'Return-path'} = 'ret';
    $header{Size}          = 'fsize';

    for (qw[Return-path From To Cc Subject Date Size]) {
        next unless exists $msg{$header{$_}};

        print "  ${cmsg}$_${cend}: $msg{$header{$_}}\n";
    }

    return;
}

# Display message list
# pass parameter of queue NOT to list! i.e. if you want remote only, pass L
# if you want local, pass R  if you want all pass anything else eg A
sub list_msg {
    my $q = shift;
    
    for my $msg (keys %$msglist) {
        if (!$summary) {
            if ($q eq 'L') {
                if ($msglist->{$msg}{local}) {
                    show_msg_info($msg);
                }
            }
            if ($q eq 'R') {
                if ($msglist->{$msg}{remote}) {
                    show_msg_info($msg);
                }
            }
            if ($q eq 'A') {
                if ($msglist->{$msg}{local}) {
                    show_msg_info($msg);
                }
                if ($msglist->{$msg}{remote}) {
                    show_msg_info($msg);
                }
            }
        } ## end if ($summary == 0)
    } ## end foreach my $msg (@msglist)

    stats();
    return;
}

# View a message in the queue
#
sub view_msg {
    my $rmsg = shift;
    
    if ($rmsg =~ /\D/) {
        warn "$rmsg is not a valid message number!\n";
        return;
    }

    # Search message
    my $ok = 0;
    for my $msg(keys %$msglist) {
        if ($msg =~ /\/$rmsg$/) {
            $ok = 1;
            print "\n --------------\nMESSAGE NUMBER $rmsg \n --------------\n"; 
            open (my $msg_fh, '<', "${queue}mess/$msg");
            while (<$msg_fh>) {
                print $_;
            }
            close ($msg_fh);
            last;
        }
    }

    # If the message isn't found, print a notice
    if (!$ok) {
        warn "Message $rmsg not found in the queue!\n";    
    }

    return;    
}

sub trash_msgs {
    my @todelete = ();
    my $grouped = 0;
    my $deleted = 0;
    foreach my $msg (@todel) {
        $grouped++;
        $deleted++;
        my ($dirno, $msgno) = split(/\//, $msg);
        if ($msglist->{$msg}{bounce}) {
            push @todelete, "${queue}bounce/$msgno";
        }
        push @todelete, "${queue}mess/$msg";
        push @todelete, "${queue}info/$msg";
        if ($msglist->{$msg}{remote}) {
            push @todelete, "${queue}remote/$msg";
        }
        if ($msglist->{$msg}{local}) {
            push @todelete, "${queue}local/$msg";
        }
        if ($msglist->{$msg}{todo}) {
            push @todelete, "${queue}todo/$msglist->{$msg}{'todo'}";
            push @todelete, "${queue}intd/$msglist->{$msg}{'todo'}";
        }
        if ($grouped == 11) {
            unlink @todelete;
            @todelete = ();
            $grouped = 0;
        }
    }
    if ($grouped) {
        unlink @todelete;
    }
    warn "Deleted $deleted messages from queue\n";
    return;
}

sub flag_msgs {
    my $now = time;
    my @flagqueue = ();
    my $flagged = 0;
    foreach my $msg (@toflag) {
        push @flagqueue, "${queue}info/$msg";
        $flagged++;
        if ($flagged == 30) {
            utime $now, $now, @flagqueue;
            $flagged = 0;
            @flagqueue = ();
        }
    }
    if ($flagged) {
        utime $now, $now, @flagqueue;
    }
    return;
}

# Delete a message in the queue
sub del_msg {
    my $rmsg = shift;
    
    if ($rmsg =~ /\D/) {
        warn "$rmsg is not a valid message number!\n";
        return;
    }

    # Search message
    my $ok = 0;
    for my $msg(keys %$msglist) {
        if ($msg =~ /\/$rmsg$/) {
            $ok = 1;
            push @todel, $msg;
            warn "Deleting message $rmsg...\n";
            last;
        }
    }

    # If the message isn't found, print a notice
    if (!$ok) {
        warn "Message $rmsg not found in the queue!\n";
    }

    return;
}

sub del_msg_from_sender {
    my $badsender = shift;

    warn "Looking for messages from $badsender\n";

    my $ok = 0;
    for my $msg (keys %$msglist) {
        if ($msglist->{$msg}{sender}) {
            my $sender = get_sender($msg);
            if ($sender eq $badsender) {
                $ok = 1;
                my ($dirno, $msgno) = split(/\//, $msg);
                print "Message $msgno slotted for deletion\n";
                push @todel, $msg;
            }
        }
    }
# If no messages are found, print a notice
    if (!$ok) {
        warn "No messages from $badsender found in the queue!\n";
    } 

    return;
}

sub del_msg_from_sender_r {
    my $badsender = shift;

    warn "Looking for messages from senders matching $badsender\n";

    my $ok = 0;
    for my $msg (keys %$msglist) {
        if ($msglist->{$msg}{sender}) {
           my $sender = get_sender($msg);
           if ($sender =~ /$badsender/) {
               $ok = 1;
               my ($dirno, $msgno) = split(/\//, $msg);
               print "Message $msgno slotted for deletion\n";
               push @todel, $msg;
           }
        }
    }
# If no messages are found, print a notice
    if (!$ok) {
        warn "No messages from senders matching ",
             "$badsender found in the queue!\n";
    } 

    return;
}

sub del_msg_header_r {
    my $case = shift;
    my $re = shift;

    warn "Looking for messages with headers matching $re\n";

    my $ok = 0;
    for my $msg (keys %$msglist) {
    open (my $msg_fh, '<', "${queue}mess/$msg")
        or die("cannot open message $msg! Is qmail-send running?\n");
    while (<$msg_fh>) {
        if ($case eq 'C') {
            if (/$re/) {
                $ok = 1;
                my ($dirno, $msgno) = split(/\//, $msg);
                warn "Message $msgno slotted for deletion.\n";
                push @todel, $msg;
                last;
            } elsif ( $_ eq "\n") {
                last;
            }
        } else {
            if (/$re/i) {
                $ok = 1;
                my ($dirno, $msgno) = split(/\//, $msg);
                warn "Message $msgno slotted for deletion.\n";
                push @todel, $msg;
                last;
            } elsif ( $_ eq "\n") {
                last;
            }
        }
    }
    close ($msg_fh);

    }
    # If no messages are found, print a notice
    if (!$ok) {
        warn "No messages with headers matching $re found in the queue!\n";
    } 

    return;
}

sub del_msg_body_r {
    my $case = shift;
    my $re = shift;
    my $nomoreheaders = 0;

    warn "Looking for messages with body matching $re\n";

    my $ok = 0;
    for my $msg (keys %$msglist) {
    open (my $msg_fh, '<', "${queue}mess/$msg")
        or die("cannot open message $msg! Is qmail-send running?\n");
    while (<$msg_fh>) {
        if ($nomoreheaders == 1) {
            if ($case eq 'C') {
                if (/$re/) {
                    $ok = 1;
                    my ($dirno, $msgno) = split(/\//, $msg);
                    warn "Message $msgno slotted for deletion.\n";
                    push @todel, $msg;
                    last;
                }
            } else {
                if (/$re/i) {
                    $ok = 1;
                    my ($dirno, $msgno) = split(/\//, $msg);
                    warn "Message $msgno slotted for deletion.\n";
                    push @todel, $msg;
                    last;
                }
            }
        }
        else {
            if ($_ eq "\n") {
                $nomoreheaders = 1;
            }
        }
    }
    close ($msg_fh);
    $nomoreheaders = 0;

    }
    # If no messages are found, print a notice
    if (!$ok) {
        warn "No messages with body matching $re found in the queue!\n";
    }

    return;
}

sub del_msg_subj {
    my $subject = shift;

    warn "Looking for messages with Subject: $subject\n";

    # Search messages
    my $ok = 0;
    for my $msg (keys %$msglist) {
        my ($dirno, $msgno) = split(/\//, $msg);
        my $msgsub = get_subject($msg);

        if ($msgsub and $msgsub =~ /$subject/) {
            $ok = 1;
            warn "Deleting message: $msgno\n";
            push @todel, $msg;
        }

    }

    # If no messages are found, print a notice
    if (!$ok) {
        warn "No messages matching Subject \"$subject\" found in the queue!\n";
    }

    return;
}


# Delete all messages in the queue (thanks Kasper Holtze)
sub del_all {

    # Search messages
    my $ok = 0;
    for my $msg (keys %$msglist) {
        $ok = 1;
        my ($dirno, $msgno) = split(/\//, $msg);
        warn "Message $msgno slotted for deletion!\n";
        push @todel, $msg;
    }

    # If no messages are found, print a notice
    if (!$ok) {
        warn "No messages found in the queue!\n";
    } 

    return;
}

sub flag_remote {
    my $re = shift;

    warn "Looking for messages with recipients in $re\n";

    my $ok = 0;
    for my $msg (keys %$msglist) {
        if ($msglist->{$msg}{remote}) {
            open (my $msg_fh, '<', "${queue}remote/$msg")
                or die("cannot open remote file for message $msg! ",
                       "Is qmail-send running?\n");
            my $recipients = <$msg_fh>;
            chomp($recipients);
            close ($msg_fh);
            if ($recipients =~ /$re/) {
                $ok = 1;
                push @toflag, $msg;
                warn "Message $msg being tagged for earlier retry ",
                     "(and lengthened stay in queue)!\n"
            }
        }
    }
    # If no messages are found, print a notice
    if (!$ok) {
        warn "No messages with recipients in $re found in the queue!\n";
        return;
    }

    flag_msgs();

    return;
}

# Make statistics
sub stats {
    my $total = 0;
    my $l = 0;
    my $r = 0;
    my $b = 0;
    my $t = 0;

    foreach my $msg (keys %$msglist) {
        $total++;
        if ($msglist->{$msg}{local}  ) { $l++; }
        if ($msglist->{$msg}{remote} ) { $r++; }
        if ($msglist->{$msg}{bounce} ) { $b++; }
        if ($msglist->{$msg}{todo} ) { $t++; }
    }

   print <<"END_OF_STATS";
${cstat}Total messages${cend}: $total
${cstat}Messages with local recipients${cend}: $l
${cstat}Messages with remote recipients${cend}: $r
${cstat}Messages with bounces${cend}: $b
${cstat}Messages in preprocess${cend}: $t
END_OF_STATS
   return;
}

# Retrieve pid of qmail-send
sub qmail_pid {
    my $qmpid = `$pidcmd`;
    chomp ($qmpid);
    $qmpid =~ s/\s+//g;
    if ($qmpid =~ /^\d+$/) { return $qmpid; }
    return 0;
}

# Print help
sub usage {
    print <<"END_OF_HELP";
$me v$version
Copyright (c) 2016 Dave Cross <dave\@perlhacks.com>
Based on original version by Michele Beltrame <mb\@italpro.net>

Available parameters:
  -a       : try to send queued messages now (qmail must be running)
  -l       : list message queues
  -L       : list local message queue
  -R       : list remote message queue
  -s       : show some statistics
  -mN      : display message number N
  -dN      : delete message number N
  -fsender : delete message from sender
  -f're'   : delete message from senders matching regular expression re
  -Stext   : delete all messages that have/contain text as Subject
  -h're'   : delete all messages with headers matching regular expression re (case insensitive)
  -b're'   : delete all messages with body matching regular expression re (case insensitive)
  -H're'   : delete all messages with headers matching regular expression re (case sensitive)
  -B're'   : delete all messages with body matching regular expression re (case sensitive)
  -t're'   : flag messages with recipients in regular expression 're' for earlier retry (note: this lengthens the time message can stay in queue)
  -D       : delete all messages in the queue (local and remote)
  -V       : print program version

Additional (optional) parameters:
  -c       : display colored output
  -N       : list message numbers only
           (to be used either with -l, -L or -R)

You can view/delete multiple message i.e. -d123 -m456 -d567

END_OF_HELP

    exit;
}

# Print help
sub version {
    print "$me v$version\n";
    return;
}

