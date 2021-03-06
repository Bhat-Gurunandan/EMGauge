#!/usr/bin/perl

use strict;
use warnings;

use lib::abs qw{/home/nandan/workspace/EMGauge/emgauge/lib};

use EMGauge::Constants;

use EMGaugeDB::Recipient;
use EMGaugeDB::XLParseQueue;
use EMGaugeDB::Listmembers;

use Getopt::Long;
use Config::Simple;
use Spreadsheet::ParseExcel;
use Email::Valid;
use Digest::SHA qw{sha1_hex};
use Data::Serializer;

my $pqid = 0;
my $jobid = 0;

GetOptions(
	'pqid=i' => \$pqid,
	'jobid=i' => \$jobid,
);

($pqid and $jobid) || die "Parse and/or Job Ids not available";
my $pq = EMGaugeDB::XLParseQueue->retrieve(id => $pqid) || exit $jobid;
($pq->bjobid == $jobid) or exit $jobid;

my $fname = $pq->filename;
my $listid = $pq->listid->id;

my $list = EMGaugeDB::List->retrieve(id => $listid);

my $cfg = Config::Simple->new($EMGauge::Constants::confdir . '/EMGauge.conf');

my $srlzr = Data::Serializer->new(
	serializer => 'Storable',
	digester   => 'MD5',
	cipher     => 'DES',
	secret     => $cfg->param('Mail.DigestSekrit'),
	compress   => 1,
);

my $group = $srlzr->deserialize($pq->importfields);

my $header;
my $data;
my $rowhash = {};
my $prevrow = 1;
my $recordcount = 0;
my $validemail = 1;

my $rdcell = sub {

	my ($wb, $wsidx, $row, $col, $cell) = @_;
	
	return unless $group->[$wsidx];
	
	return unless ($row); # Dont read header row

	if ($row != $prevrow) {
		if ($validemail) {
			++$recordcount if (_add_recipient($rowhash, $list));
			$rowhash = {};
		}
		$validemail = 1;
	}

	my $value;
	if ($group->[$wsidx]->[$col] eq 'dob') {

		if (defined $cell->{Type} && $cell->{Type} eq 'Date') {
			$value = ExcelFmt('yyyy/mm/dd', $cell->unformatted());
		}
		else {
			$value = ParseDate($cell->value()) ? UnixDate($cell->value(), '%Y/%m/%d') : undef;
		}
	}
	elsif ($group->[$wsidx]->[$col] eq 'email') {
		
		if (! ($value = Email::Valid->address($cell->value()))) {
			$validemail = 0;
		}
	}
	else {
		$value = $cell->value();
	}

	$rowhash->{$group->[$wsidx]->[$col]} = $value if ($group->[$wsidx]->[$col] ne '0');

	$prevrow = $row;
};

my $parser = Spreadsheet::ParseExcel->new(CellHandler => $rdcell, NotSetCell => 1);
my $wb = $parser->Parse($fname);

if (_add_recipient($rowhash, $list)) {
	++$recordcount;
};

$pq->recordsin($recordcount);
$pq->update;

$list->records($recordcount + $list->records);
$list->update;

exit $jobid;

sub _add_recipient{

	return 0 unless $rowhash;
	
	my $rcpt;
	my $added;

	my $demail  = EMGaugeDB::Recipient->retrieve(email => $rowhash->{email});
	if (!$demail) { 
		$rcpt = EMGaugeDB::Recipient->insert($rowhash); 
	}
	else {
		$rcpt = EMGaugeDB::Recipient->retrieve(email => $demail->email);
		while ( my ($key, $value) = each(%$rowhash) ) { 
			$rcpt->$key($value) if $value;
		}
		$rcpt->update();
	}

	my $inlist = $rcpt->subscriptions(list => $list->id);
	
	if (!$inlist) {
		$list->add_to_members({recipient => $rcpt,});
		++$added;
	}

	return $added;
}

