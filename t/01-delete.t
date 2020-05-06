#!/usr/bin/perl
use warnings;
use strict;

use Test::Spec;
use Test::Warn;

use QMail::QueueHandler;

describe method => sub {
    my $qm;
    before each => sub {
        close *STDOUT;
        open *STDOUT, '>', \(my $output);

        $qm = 'QMail::QueueHandler'->new;
    };

    describe del_all => sub {

        it 'warns on no messages' => sub {
            $qm->expects('msglist')->returns({});

            warnings_like {
                $qm->del_all;
            } [ qr/No messages found in the queue!/ ];
        };

        it 'adds messages to delete' => sub {
            my $message = 'msg';
            $qm->expects('msglist')->returns({ "$message" => 'x' });
            $qm->expects('add_to_delete')->with($message);

            $qm->del_all;
        };
    };

    describe del_msg_from_sender => sub {
        my $msg_id = 'm1';
        my $warn_always = qr/Looking for messages from /;
        my $del_msg_from = sub {
            my ($sender) = @_;
            $qm->expects('msglist')
                ->returns({ $msg_id => { sender => 1 } })
                ->exactly(2);
            $qm->expects('get_sender')
                ->with($msg_id)
                ->returns('jane');
            $qm->del_msg_from_sender($sender);
        };

        it 'warns on no messages found' => sub {
            warnings_like {
                $del_msg_from->('joe');
            } [ $warn_always,
                qr/No messages from joe found in the queue!/
              ];
        };

        it 'finds a message' => sub {
            warnings_like {
                $del_msg_from->('jane');
            } [ $warn_always,
                qr/Message \[$msg_id\] queued for deletion./
              ];
        };

    };
};

runtests();
