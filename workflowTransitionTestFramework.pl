use strict;
use ElectricCommander;
use Getopt::Long;
use XML::Simple;
use Data::Dumper;

my $project;        # project to use to create the tests under
my $testXml;        # the xml file that contains the transition and tests you want to run on that transition
my $epoch = time(); # used to make the names unique since we will be cleaning up after ourselves and may run this twice.  
		    #note that if this runs multiple times in the same second this won't work, but for now don't worry about that.
my $debug=0;
my $timeoutTime=300; #by default assume all our tests will complete in 5 minutes

# validate incoming arguments
my $argumentErrors;
GetOptions(
	"project|p=s"=>\$project,
	"testXml|xml=s"=>\$testXml,
	"debug"=>\$debug,
	"timeout=i"=>\$timeoutTime
	) 
or die("Error in command line arguments\n");

if($project eq "") {
	$argumentErrors .= "ERROR: Project name cannot be blank\n";
}

if(!(-f $testXml)) {
	$argumentErrors .= "ERROR: $testXml is not a valid file\n";
}

if($argumentErrors ne "") {
	die($argumentErrors);
}


my $ec = ElectricCommander->new();

# all names will use the epoch time to make them
# "unique".  note if you run more than one in a second you might get failures
my $workflowDefName = "workflow$epoch";
my $setupProcedure  = "procedure$epoch";
my $subprocedure    = "subprocedure$epoch";
my $subworkflow     = "subworkflow$epoch";

# create the workflow definition
$ec->createWorkflowDefinition("$project", "$workflowDefName") if(!$debug);

# create the setup procedure
$ec->createProcedure("$project", "$setupProcedure") if(!$debug);

# create the parameter you need with the script in it
$ec->createFormalParameter("$project", "$setupProcedure", "setupScript", {required=>1}) if(!$debug);

# create a step to run the setup script.  the setup script is simply 
# one step that takes a parameter setupScript which is the script that 
# it should run and puts that as the command.  it sets the shell as ec-perl
$ec->createStep("$project", "$setupProcedure", "runSetupScript", {command=>'$[setupScript]', shell=>'ec-perl'}) if(!$debug);


# create setup state in the workflow definition
$ec->createStateDefinition("$project", "$workflowDefName", "Setup", {startable=>1, subprocedure=>$setupProcedure,subproject=>$project, actualParameter=>[{actualParameterName=>"setupScript",value=>'$[setupScript]'}]}) if(!$debug);
$ec->createFormalParameter("$project", "setupScript", {formalParameterName=>"setupScript", workflowDefinitionName=>"$workflowDefName", stateDefinitionName=>"Setup", "type"=>"textarea", "required"=>1}) if(!$debug);

# read the XML file to find out what type of a state we will be creating
# for the transition along with any sub procedures or other things we need
# to create
my $xml = new XML::Simple;
my $testsHash = $xml->XMLin($testXml, ForceArray=>['test', 'property']);
print Dumper($testsHash) if($debug);


my $transitionStateType = $testsHash->{'stateType'};
my $transition = $testsHash->{'transition'};

# for noAction states simply create the state (defaults to no action)
if($transitionStateType eq "noAction") {
	$ec->createStateDefinition("$project", "$workflowDefName", "Transition" ) if(!$debug);
}

# for a subprocedure, we must create the sub procedure with one step.
# the step will have passed in the parameter subprocedureScript
if($transitionStateType eq "subprocedure") {
	# create the setup procedure
	$ec->createProcedure("$project", "$subprocedure") if(!$debug);
	$ec->createStep("$project", "$subprocedure", "runScript", {command=>'$[subprocedureScript]', shell=>'ec-perl'}) if(!$debug);

	# create the parameter you need with the script in it
	$ec->createFormalParameter("$project", "$subprocedure", "subprocedureScript", {required=>1}) if(!$debug);
	
	$ec->createStateDefinition("$project", "$workflowDefName", "Transition", {subprocedure=>$subprocedure,subproject=>$project, actualParameter=>[{actualParameterName=>"subprocedureScript",value=>'$[subprocedureScript]'}]}) if(!$debug);
	$ec->createFormalParameter("$project", "setupScript", {formalParameterName=>"subprocedureScript", workflowDefinitionName=>"$workflowDefName", stateDefinitionName=>"Setup", "type"=>"textarea", "required"=>1}) if(!$debug);
}

# create on completion transition from Setup -->Transition state
$ec->createTransitionDefinition("$project", "$workflowDefName", "Setup", "beginTransition", "Transition", {trigger=>"onCompletion"} ) if(!$debug);

# create the two possible final states (either the transition was taken or not taken)
$ec->createStateDefinition("$project", "$workflowDefName", "transitionTaken" ) if(!$debug);
$ec->createStateDefinition("$project", "$workflowDefName", "transitionNotTaken") if(!$debug);

# create transitions from out state using our transition condition and from the trigger state
my $transitionTrigger = ($transitionStateType eq "noAction") ? "onEnter" : "onCompletion";
$ec->createTransitionDefinition("$project", "$workflowDefName", "Transition", "transitionTakenPath", "transitionTaken", {trigger=>"$transitionTrigger", "condition"=>"$transition"} ) if(!$debug);
$ec->createTransitionDefinition("$project", "$workflowDefName", "Transition", "transitionNotTakenPath", "transitionNotTaken", {trigger=>"$transitionTrigger"} ) if(!$debug);

# keep an array of all the workflows we submit so we can later 
# loop and check the status
my %workflowsSubmitted; 

# loop thru the tests to run and run them
if($testsHash->{'test'}) {
	foreach my $testName(keys %{$testsHash->{'test'}}) {
		my $finalState = $testsHash->{'test'}->{$testName}->{'finalState'};
		my $subprocedureScript = "";
		my $scriptToPass = <<SCRIPT;
use strict;
use ElectricCommander();
my \$ec = new ElectricCommander();
SCRIPT
		if($testsHash->{'test'}->{$testName}->{'property'}) {
			foreach my $propName(keys %{$testsHash->{'test'}->{$testName}->{'property'}}) {
				my $propVal = $testsHash->{'test'}->{$testName}->{'property'}->{$propName}->{'value'};
				$scriptToPass .= "\n\$ec->setProperty(\"$propName\", \"$propVal\");";
			}
		}
		if($transitionStateType eq "subprocedure") {
			if($testsHash->{'test'}->{$testName}->{'subprocedureScript'}) {
				$subprocedureScript = $testsHash->{'test'}->{$testName}->{'subprocedureScript'};
			}
			
		}
		print $testName." - $finalState \n" if($debug);
		print "\t$scriptToPass\n\n" if($debug);
		
		# run the workflow passing in the script we created
		if($transitionStateType eq "noAction") {
			my $result = $ec->runWorkflow("$project", "$workflowDefName", {startingState=>'Setup', actualParameter=>[{actualParameterName=>'setupScript',value=>"$scriptToPass"}]}) if(!$debug);
			my $workflowName = $result->findvalue("//workflow/workflowName");
			print "WORKFLOW: $workflowName\n" if($debug);
			$workflowsSubmitted{$workflowName}{'completed'}="0";
			$workflowsSubmitted{$workflowName}{'expectedFinalState'}=$finalState;
		} 

		if($transitionStateType eq "subprocedure") {
			my $result = $ec->runWorkflow("$project", "$workflowDefName", {startingState=>'Setup', actualParameter=>[{actualParameterName=>'setupScript',value=>"$scriptToPass"}, {actualParameterName=>'subprocedureScript',value=>"$subprocedureScript"}]}) if(!$debug);
			my $workflowName = $result->findvalue("//workflow/workflowName");
			print "WORKFLOW: $workflowName\n" if($debug);
			$workflowsSubmitted{$workflowName}{'completed'}="0";
			$workflowsSubmitted{$workflowName}{'expectedFinalState'}=$finalState;
		}
		
	}	
}

# loop thru all of the workflows that we submitted and wait for them to complete. 
# then get the active state of them 
my $numCompleted=0;
my $numWorkflows=scalar keys(%workflowsSubmitted);
my %completedWorkflows;

while($numCompleted<$numWorkflows) {
	foreach my $workflow(keys %workflowsSubmitted) {
		if(!$completedWorkflows{$workflow}) {
			my $workflowXpath = $ec->getWorkflow("$project", "$workflow");
			my $completed = $workflowXpath->findvalue("//workflow/completed");
				print "COMPLETED: $completed\n" if($debug);
				if("$completed" == "1") {
					my $finalState=$workflowXpath->findvalue("//workflow/activeState");
					$numCompleted+=1;
					$completedWorkflows{$workflow}=1;
					$workflowsSubmitted{$workflow}{'actualFinalState'} = $finalState;
					$workflowsSubmitted{$workflow}{'completed'} = "1";

				}
			
		}
	}
}

# test to make sure that the active state equals the expected state
foreach my $workflow(keys %workflowsSubmitted) {
	my $expectedState = $workflowsSubmitted{$workflow}{'expectedFinalState'};
	my $actualState   = $workflowsSubmitted{$workflow}{'actualFinalState'};
	my $completed  = $workflowsSubmitted{$workflow}{'completed'};
	
	my $testStatus = ($expectedState eq $actualState) ? "PASS" : "FAIL";
	if($completed eq "1") {
		print "$testStatus: $workflow was submitted with expected final state $expectedState and completed with final state $actualState\n";
	} else {
		print "FAIL: $workflow was submitted but did not complete in $timeoutTime";
	}
}
