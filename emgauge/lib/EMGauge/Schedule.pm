package EMGauge::Schedule;

use strict;
use warnings;

use Beanstalk::Client;
use Data::Serializer;
use Data::Dumper;
use Date::Manip;
use Date::Calc;
use POSIX qw{strftime};

use Data::FormValidator;

use ex::lib qw(../);
use base qw(EMGauge);

use EMGaugeDB::Mailer;
use EMGaugeDB::List;
use EMGaugeDB::Schedule;
use EMGaugeDB::DeliveryLog;
use EMGaugeDB::MailerLog;


sub setup {

	my $app = shift;
	$app->authen->protected_runmodes(':all');
}

sub list : StartRunmode {

	my $app = shift;
	my $tpl = $app->load_tmpl('schedule/list.tpl', die_on_bad_params => 0, loop_context_vars => 1);

	my $page = $app->query->param('page') || 1;
	my $pager = EMGaugeDB::Schedule->pager(
		where => {scheduledby => $app->authen->username},
		order_by => 'id desc',
		per_page => $app->config_param('View.ItemsPerPage'),
		page => $page,
	);
	
	my @schedules = map{

		my @mailerlog = EMGaugeDB::MailerLog->search(schedule => $_->id);
		my ($schd, $dlvrd) = ($mailerlog[0]->scheduled, $mailerlog[0]->delivered);

		my $mlr = EMGaugeDB::Mailer->retrieve(id => $_->mailer);
		
		{
			SCHEDULEID => $_->id,
			SCHEDULENAME => $_->name,
			SCHEDULEMAILERID => $mlr->id,
			SCHEDULEMAILERNAME => $mlr->name,
			SCHEDULEMAILERSUBJECT => $mlr->subject,
			SCHEDULELISTS => (join ', ', map {$_->name . ' (' . $_->records . ')'} $_->lists),
			SCHEDULEON => UnixDate($_->scheduledfor, '%a, %d %b \'%y %H:%M'),
			SCHEDULEDELIVERED => $dlvrd,
			SCHEDULECOUNT => $schd,
			SCHEDULESTATUS => status2str($_->status),
			SCHEDULEPAUSABLE => ($_->status == 1),
			SCHEDULEPAUSED => ($_->status == 2),
			SCHEDULEREPEATED => $_->repeated,
	}} $pager->search_where;

	$tpl->param(
		SCHEDULE => \@schedules,
		PAGENAV => $app->pager($page, $pager->last_page),
	);
		return $tpl->output;
}

sub save_step0 : Runmode {
	
	my $app = shift;
	my $q = $app->query;
	
	# We might be in Edit Mode so check for schedule to edit
	my $scheduleid = $q->param('scheduleid') || 0;
	my $schedule = EMGaugeDB::Schedule->retrieve(id => $scheduleid);

	# Required for edit or assign mode. Zero/Null in create mode
	my $mailerid = $schedule ? $schedule->mailer : ($q->param('mailerid') || 0);
	my $schedulename = $schedule ? $schedule->name : undef;
		
	my $tpl = $app->load_tmpl('schedule/save_step0.tpl', die_on_bad_params => 0, loop_context_vars => 1);

	my @mymailers = map {{
		MAILERID => $_->id,
		MAILERNAME => $_->name,
		MAILERSELECTED => ($_->id == $mailerid) ? 1 : 0,
	}} EMGaugeDB::Mailer->mymailers($app->authen->username);

	$tpl->param(
		SCHEDULEID => $scheduleid,
		SCHEDULENAME => $schedulename,
		MAILERID => $mailerid,
		MAILERS => \@mymailers,
	);
	
	return $tpl->output;
}

sub save_step1 : Runmode {
	
	my $app = shift;
	my $q = $app->query;

	my $dfv = {
		required => [ qw{
			schedulename 
			scheduleid 
			mailerid
		}],
		filters => 'trim',
		field_filters => {
			mailerid => ['digit'],
			scheduleid => ['digit'],
		},
		constraint_methods => {
			mailerid => sub {return (pop > 0)},
		},
		msgs => {
			prefix => 'err_',
			any_errors => 'some_errors',
		},
	};

	my $check = Data::FormValidator->check($q, $dfv);
	my $valids = $check->valid;

	if ($check->has_invalid or $check->has_missing) {

		my $scheduleid = $valids->{scheduleid} || 0;
		my $mailerid = $valids->{mailerid} || 0;
		my $schedulename = $valids->{schedulename} || undef;

		my @mymailers = map {{
			MAILERID => $_->id,
			MAILERNAME => $_->name,
			MAILERSELECTED => ($_->id == $mailerid) ? 1 : 0,
		}} EMGaugeDB::Mailer->mymailers($app->authen->username);
	
		my $tpl = $app->load_tmpl('schedule/save_step0.tpl', die_on_bad_params => 0);

		$tpl->param($check->msgs);
		$tpl->param($valids);
		$tpl->param(
			SCHEDULEID => $scheduleid,
			SCHEDULENAME => $schedulename,
			MAILERID => $mailerid,
			MAILERS => \@mymailers,
		);

		return $tpl->output;
	}

	# Mailerid and Schedulename are guaranteed to exist here!
	# Get mailerid and mailer. Die if not found!
	my $mailerid = $valids->{mailerid};
	my $mailer = EMGaugeDB::Mailer->retrieve(id => $mailerid);

	my $scheduleid = $valids->{scheduleid} || 0;
	my $schedule = EMGaugeDB::Schedule->retrieve(id => $scheduleid);

	my $schedulename = $valids->{schedulename};
		
	# Create array of ids of assigned/all lists. Diff is calculated later 

	my (@assoclists, @unassoclists);
	my @allids = map { $_->id } EMGaugeDB::List->search(active => 1, createdby => $app->authen->username);
	my @assignedlists = $schedule ? $schedule->lists : ();
	my @assignedids = map { $_->id } @assignedlists;

	@assoclists = map {{
		LISTID => $_->id,
		LISTNAME => $_->name,		
	}} @assignedlists;

	# Get difference @allists - @assoclists 

	my %count;
	for (@assignedids, @allids) {
		++$count{$_};
	}
	my @diff;
	for (sort keys %count) {
		push @diff, $_ unless $count{$_} == 2;
	}

	@unassoclists = map{{
		LISTID => $_,
		LISTNAME => EMGaugeDB::List->retrieve(id => $_)->name,
	}} @diff;

	my $tpl = $app->load_tmpl('schedule/save_step1.tpl', die_on_bad_params => 0, loop_context_vars => 1);

	$tpl->param(
		MAILERID => $mailerid,
		MAILERNAME => $mailer->name,
		SCHEDULEID => $scheduleid,
		SCHEDULENAME => $schedulename,
		LISTCOUNT => scalar @assoclists,
		ASSIGNEDLISTS => \@assoclists,
		UNASSIGNEDLISTS => \@unassoclists,
	);

	return $tpl->output;
}

sub save_step2 : Runmode {
	
	my $app = shift;
	my $q = $app->query;

	my $dfv = {
		required => [qw{
			mailerid
			scheduleid
			schedulename 
			assignlists 
		 }],
		filters => 'trim',
		field_filters => {
			mailerid => ['digit'],
			scheduleid => ['digit'],
		},
		constraint_methods => {
			mailerid => sub {return (pop > 0)},
		},
		msgs => {
			prefix => 'err_',
			any_errors => 'some_errors',
		},
	};

	my $check = Data::FormValidator->check($q, $dfv);
	my $valids = $check->valid;

	if ($check->has_invalid or $check->has_missing) {

		my $mailerid = $valids->{mailerid};
		my $mailer = EMGaugeDB::Mailer->retrieve(id => $mailerid);
	
		my $scheduleid = $valids->{scheduleid} || 0;
		my $schedulename = $valids->{schedulename};
		my $schedule = EMGaugeDB::Schedule->retrieve(id => $scheduleid);

		my (@assoclists, @unassoclists);
		my @allids = map { $_->id } EMGaugeDB::List->retrieve_all;
		my @assignedlists = $schedule ? $schedule->lists : ();
		my @assignedids = map { $_->id } @assignedlists;
	
		@assoclists = map {{
			LISTID => $_->id,
			LISTNAME => $_->name,		
		}} @assignedlists;
	
		# Get difference @allists - @assoclists 
	
		my %count;
		for (@assignedids, @allids) {
			++$count{$_};
		}
		my @diff;
		for (sort keys %count) {
			push @diff, $_ unless $count{$_} == 2;
		}
	
		@unassoclists = map{{
			LISTID => $_,
			LISTNAME => EMGaugeDB::List->retrieve(id => $_)->name,
		}} @diff;

		my $tpl = $app->load_tmpl('schedule/save_step1.tpl', die_on_bad_params => 0, loop_context_vars => 1);

		$tpl->param($check->msgs);

		$tpl->param(
			MAILERID => $mailerid,
			MAILERNAME => $mailer->name,
			SCHEDULEID => $scheduleid,
			SCHEDULENAME => $schedulename,
			LISTCOUNT => scalar @assoclists,
			ASSIGNEDLISTS => \@assoclists,
			UNASSIGNEDLISTS => \@unassoclists,
		);

		return $tpl->output;
	}

	my $mailerid = $valids->{mailerid};
	die({type => 'error', msg => 'No Mailer Found to Assign'}) unless 
		my $mailer = EMGaugeDB::Mailer->retrieve(id => $mailerid);

	my $scheduleid = $valids->{scheduleid} || 0;
	my $schedulename = $valids->{schedulename};
	my $schedule = EMGaugeDB::Schedule->retrieve(id => $scheduleid);
	
	my (@listnames, @listids);
	foreach ($q->param('assignlists')) {
		next unless (my $list = EMGaugeDB::List->retrieve(id => $_));
		push @listnames, $list->name;
		push @listids, {LISTID => $_};
	}
	
	my $tpl = $app->load_tmpl('schedule/save_step2.tpl', die_on_bad_params => 0);
	$tpl->param(
		MAILERID => $mailerid,
		MAILERNAME => $mailer->name,
		SCHEDULEID => $scheduleid,
		SCHEDULENAME => $schedulename,
		LISTNAMES => join(', ', @listnames),
		LISTIDS => \@listids,
		SCHEDULEDATE => $schedule ? UnixDate($schedule->scheduledfor, '%A, %e %B %Y') : undef,
		SCHEDULEHOUR => $schedule ? UnixDate($schedule->scheduledfor, '%H') : undef,
		SCHEDULEMIN => $schedule ? UnixDate($schedule->scheduledfor, '%M') : undef,
	);
	
	return $tpl->output;
}


sub save_schedule : Runmode {
	
	my $app = shift;
	my $q = $app->query;

	
	if ($q->param('send') eq 'Send Now') {

		my @tstmp = split /\=/, UnixDate("61 seconds later", '%A, %e %B %Y=%H=%M');

		$q->param(-name => 'scheduledate', -value => $tstmp[0]);
		$q->param(-name => 'schedulehour', -value => $tstmp[1]);
		$q->param(-name => 'schedulemin', -value => $tstmp[2]);
	}

	my $dfv = {
		required => [qw{
			scheduleid
			mailerid 
			schedulename 
			assignlists 
			scheduledate
			schedulehour
			schedulemin
		 }],
		filters => 'trim',
		field_filters => {
			mailerid => ['digit'],
			scheduleid => ['digit'],
			schedulehour => sub {sprintf('%02d', shift)},
			schedulemin => sub {sprintf('%02d', shift)},
		},
		constraint_methods => {
			mailerid => sub {return (pop > 0)},
			scheduledate => sub {return ParseDate(pop)},
			schedulehour => sub {my $self = pop; $self =~ s/^0+//; return ($self < 24)},
			schedulemin => sub {my $self = pop; $self =~ s/^0+//; return ($self < 60)},
		},
		msgs => {
			prefix => 'err_',
			any_errors => 'some_errors',
		},
	};


	my $check = Data::FormValidator->check($q, $dfv);
	my $valids = $check->valid;
	my @validlistids = $check->valid('assignlists');
	
	if ($check->has_invalid or $check->has_missing) {

		my $tpl = $app->load_tmpl('schedule/save_step2.tpl', die_on_bad_params => 0);

		my @listnames;		
		my @listids = map {
			if (my $list = EMGaugeDB::List->retrieve(id => $_)) {
				push @listnames, $list->name;
				{LISTID => $_,};				
			}
			else {
				();
			}
		} @validlistids;
		

		$tpl->param($check->msgs);
		$tpl->param($valids);
		$tpl->param(
			LISTIDS => \@listids,
			LISTNAMES => join(', ', @listnames),
			MAILERNAME => EMGaugeDB::Mailer->retrieve(id => $valids->{mailerid})->name,
		);
		return $tpl->output;
	}

	my $clnt = Beanstalk::Client->new({
		server => $app->config_param('JobManager.BeanstalkServer'),
		default_tube => $app->config_param('JobManager.DefaultTube'),
		debug => 0,
	});

	$clnt->connect;
	die({
		type => 'error', 
		msg => 'Connect to Beanstalk Server threw error: <strong>' . $clnt->error . '</strong>. Please contact guru@dygnos.com with this error message'
	}) if $clnt->error;
	$clnt->use($app->config_param('JobManager.DefaultTube'));
	
	my $srlzr = Data::Serializer->new(
		serializer => 'Storable',
		digester   => 'MD5',
		cipher     => 'DES',
		secret     => $app->config_param('Mail.DigestSekrit'),
		compress   => 1,
	);
	
	my $schedule = $valids->{scheduleid} ? 
		EMGaugeDB::Schedule->retrieve(id => $valids->{scheduleid}) :
		EMGaugeDB::Schedule->insert({});
	my $scheduleid = $schedule->id;

	my $jobh = {
		type => 'Mail Delivery',
		dbid => $scheduleid,
		script => $app->config_param('Path.DeliverCommand') . " -s $scheduleid",
		insertedon => strftime('%Y/%m/%d %H:%M:%S', localtime),
	};

	my $scheduledfor = $valids->{scheduledate} . ' ' . $valids->{schedulehour} . ':' . $valids->{schedulemin};
	my $scheduletstmp = UnixDate("$scheduledfor", '%Y/%m/%d %H:%M:%S');

	my $job = $clnt->put({
		data => $srlzr->serialize($jobh),
		ttr => 60,
		delay => _getsecondsto($scheduletstmp),
	});
	die({type => 'error', msg => 'Insert on Beanstalk Server threw error: <strong>' . $clnt->error . '</strong> Please contact guru@dygnos.com with this error message'}) if $clnt->error;

	my $scheduled = $schedule->scheduled || 0;
	my $schtimes = $schedule->repeated || -1;
	$schedule->set(
		name => $valids->{schedulename},
		mailer => $valids->{mailerid},
		jobid => $job->id,
		scheduled => $scheduled + EMGaugeDB::Schedule->sql_count_scheduled->select_val($schedule->id),
		status => -1,
		scheduledfor => UnixDate($scheduledfor, '%Y/%m/%d %H:%M'),
		scheduledby => $app->authen->username,
		repeated => $schtimes + 1,
	);

	$schedule->schedulelists->delete_all;
	foreach (@validlistids) {
		$schedule->add_to_schedulelists({
			list => $_,
			assignedby => $app->authen->username,
		});
	}
	$schedule->update;
	
	$app->redirect('schedule.cgi');
}

sub delete_schedule : Runmode {
	
	my $app = shift;
	my $scheduleid = $app->query->param('scheduleid');
	
	my $schedule = EMGaugeDB::Schedule->retrieve(id => $scheduleid);
	$schedule->delete;
	
	$app->redirect('schedule.cgi');
}

sub pause_schedule : Runmode {
	
	my $app = shift;
	my $sid = $app->query->param('sid');
	
	my $schedule = EMGaugeDB::Schedule->retrieve(id => $sid) ||
		die({type => 'error', msg => 'No Schedule Found to Pause' . $sid});
		
	my $clnt = Beanstalk::Client->new({
		server => $app->config_param('JobManager.BeanstalkServer'),
		default_tube => $app->config_param('JobManager.DefaultTube'),
		debug => 1,
	});

	$clnt->connect;
	return '<p class="error">Connect to Beanstalk Server threw error: <strong>' . $clnt->error . '</strong>. Please contact guru@dygnos.com with this error message</p>'
		if $clnt->error;

	$clnt->use($app->config_param('JobManager.DefaultTube'));
	
	my $srlzr = Data::Serializer->new(
		serializer => 'Storable',
		digester   => 'MD5',
		cipher     => 'DES',
		secret     => $app->config_param('Mail.DigestSekrit'),
		compress   => 1,
	);
	
	my $jobh = {
		type => 'Pause Delivery',
		dbid => 0,
		script => $app->config_param('Path.PauseCommand') . " -s $sid",
		insertedon => strftime('%Y/%m/%d %H:%M:%S', localtime),
	};

	my $job = $clnt->put({
		data => $srlzr->serialize($jobh),
		ttr => 60,
	});
	return '<p class="error">Insert on Beanstalk Server threw error: <strong>' . $clnt->error . '</strong> Please contact guru@dygnos.com with this error message</p>'
		if $clnt->error;
		
	sleep 5;
	
	if (EMGaugeDB::Schedule->retrieve(id => $sid)->status == 2) {
		return '<p class="success">Delivery successfully Paused. You can restart when ready</p>';
	}
	else {
		return '<p class="error">Could not find delivery process to pause. Please contact guru@dygnos.com with this error message</p>';
	}
}

sub _getsecondsto {
	my $to = shift;

	my ($year1, $mon1, $day1, $hour1, $min1, $sec1) = Date::Calc::Today_and_Now();
	my ($year2, $mon2, $day2, $hour2, $min2, $sec2) = split /[\s+\:\/]/, $to;
	
	my ($Dd, $Dh, $Dm, $Ds) = Date::Calc::Delta_DHMS($year1, $mon1, $day1, $hour1, $min1, $sec1, $year2, $mon2, $day2, $hour2, $min2, $sec2);
	
	return 60 * (60 * (24 * $Dd + $Dh ) + $Dm) + $Ds;	
}

sub status2str {
	
	my $status = shift;

	return "Scheduled" if ($status == -1);
	return "Completed" if ($status == 0);
	return "In Progress" if ($status == 1);
	return "Stopped" if ($status == 2);
	
	return;	
}
1;
