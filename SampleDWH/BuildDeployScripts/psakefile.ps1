<###################################################################################################
# Script written by © Dr. John Tunnicliffe, 2015-2018 https://github.com/DrJohnT/devops-your-dwh
# This PowerShell script is released under the MIT license http://www.opensource.org/licenses/MIT
#
# This script contains generic tasks which can be used to build and deploy a data
# warehouse including database, SSIS and SSAS projects
####################################################################################################
#  Useful commands:
	cd "C:\Dev\QatarRe Database Development\DWH\BuildDeployScripts"
	Invoke-psake -taskList Build-All
	Invoke-psake -taskList Deploy-All
	Invoke-psake -taskList Run-Load
	Invoke-psake -taskList Deploy-SQLAgentJobs
####################################################################################################
# If you have a problem running this script, open PowerShell in administrator mode and run:
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

# Check your local ExecutionPolicy using:
    Get-ExecutionPolicy -list

# If you find that PowerShell cannot find psake, then run
 	Install-Module -Name psake 

# If you find that PowerShell cannot find Invoke-SqlCmd or Invoke-AsCmd, then the SqlServer module is missing, then run
	UnInstall-Module -Name SqlPs -Force  
	UnInstall-Module -Name SqlServer -Force
	Install-Module -Name SqlServer -AllowClobber -Force -RequiredVersion 21.0.17199  # MUST be this version as new version does not work!!!!!

# To check which modules you have installed, run
	Get-Module -ListAvailable
####################################################################################################>

#region Properties

# Read the local config parameters

Properties {
    [string]$targetEnvironment = "TST";

	# change this path as appropriate
	[string]$CommonScriptsPath = ".\..\..\CommonScripts";
	$includeScripts = @();
	$includeScripts += "ExePaths.ps1";
	$includeScripts += "BuildFunctions.ps1";
	$includeScripts += "MsTestFunctions.ps1";
	$includeScripts += "ReadConfigFunctions.ps1";
	$includeScripts += "SqlCmdFunctions.ps1";
	$includeScripts += "SqlSsasFunctions.ps1";
	$includeScripts += "SqlSsdtFunctions.ps1";
	$includeScripts += "SqlSsrsFunctions.ps1";
	$includeScripts += "SqlSsisFunctions.ps1";

	foreach ($script in $includeScripts) {
		[string]$scriptPath = Resolve-Path "$CommonScriptsPath\$script";
		#Write-host $scriptPath;
		. $scriptPath;
	}

	# set up other properties
	[string]$SolutionName = "DWH";  # default solution

	[string]$BuildDirPath = $psake.build_script_dir;
	[string]$RootPath = Resolve-Path "$BuildDirPath\..";
	[string]$TempPath = Resolve-Path "$RootPath\..\..";
	$TempPath = Join-Path $TempPath "Temp";
    [string]$TestDataPath = Join-Path $RootPath "Test\TestData";
    [string]$TestResultsPath = Join-Path $RootPath "TestResults";
    [string]$SqlScriptPath = Join-Path $RootPath "Databases\SqlScripts";
    [string]$TmslScripts = Join-Path $RootPath "SSAS\TmslScripts";
	[string]$SsrsScripts = Join-Path $RootPath "SSRS\Scripts";
    [string]$SsisDeploySQLScriptPath = Join-Path $SqlScriptPath "SSIS_Deploy_SQLScripts";
    [string]$SsasSolutionName = "QuantumCubes";
	[string]$SsisSolutionName = "Load_DWH";
	

    # following are added to the SQLCmdVaribles by Get-SqlCmdVariablesFromConfig below
    [string]$DomainName = "QREGROUP";
    [string]$JobCategory = "QRE_DWH";
	
    [string]$SsisCredentialName = "SVC_SSIS";
    [string]$SsisProxyName = "SVC_SSIS_Proxy";
		
    [string]$SsasCredentialName = "SVC_SSAS";
    [string]$SsasProxyName = "SVC_SSAS_Proxy";
	
    [string]$QDMOperatorName = "SmoothOperator";
    [string]$QDMOperatorEmail = "quantumdatamartadmin@qregroup.com";

	if (!(Test-Path $TempPath)) {
		New-Item $TempPath -Type directory;
	}

	$Host.UI.RawUI.ForegroundColor = "White";
	$UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name;
	$machineName = [Environment]::MachineName;
	$framework = $psake.context.peek().config.framework;

    # Set variables for local builds.  Note that these are overridden below by VSTS
	[int] $ReleaseNumber = 1;
	
	[string] $databaseSuffix = "";
	[bool] $runPreDeployScripts = $true;
	[bool] $runPostDeployScripts = $true;
	$deployConfigFileName = "Config.xml"

	[bool] $runFromVstsOrOctopus = $false;
	[string]$environmentGroup = "DEV";

    if ($OctopusEnvironmentName)
	{
        $targetEnvironment = $OctopusEnvironmentName;
		$runFromVstsOrOctopus = $true;
		$configuration="Release";
        $SQLServerInstance = $OctopusParameters["TargetSQLServerInstance"];
        $buildNumber = $OctopusParameters["Octopus.Release.Number"];
		Write-Host "Running from Octopus";
	}
	else
	{
        $date = Get-Date -Format "yyyyMMdd";
	    $time = Get-Date -Format "HHmmss";
        $buildNumber = "$ReleaseNumber.$date.$time.$targetEnvironment";
		$configuration = "Debug";
	}

	if ($Env:TF_BUILD)  # set by VSTS build to true
	{
		$runFromVstsOrOctopus = $true;
		$targetEnvironment = "$Env:TargetEnvironment";
		Write-Host "Running from VSTS";
		# we are running from VSTS, so override anything set in the ConfigLocal.ps1 or above
		# Full list of env variables here: https://www.visualstudio.com/en-us/docs/build/define/variables
		$ReleaseNumber = "$Env:ReleaseNumber";
		# Equivalent in VSTS is $(ReleaseNumber).$(BuildID).$(SOURCEVERSION)  
		#		$(rev:.r)
		$buildNumber = "$ReleaseNumber.$Env:BUILD_BUILDID.$env:BUILD_SOURCEVERSION";
		$databaseSuffix = "$Env:DatabaseSuffix";
		$deployConfigFileName = "$Env:DeployConfigFileName";
		$runPreDeployScripts = [System.Convert]::ToBoolean($Env:RunPreDeployScripts);
		$runPostDeployScripts = [System.Convert]::ToBoolean($Env:RunPostDeployScripts);
		$configuration = "$Env:BuildConfiguration";		
	}
	elseif (!($targetEnvironment -eq "DEVVM" -or $targetEnvironment -eq "DEV") -and !($runFromVstsOrOctopus))  # only checked when not called from VSTS or Octopus
    {
		$inputValue = Read-Host "Are you sure you want to run action against $targetEnvironment ???"
        assert ($inputValue -eq "y") "Aborted action";
    }  
	Write-Host "Deploying to Environment $targetEnvironment" -ForegroundColor Yellow;
	
	$deployConfigFilePath = Join-Path $BuildDirPath $deployConfigFileName;
	assert(Test-Path($deployConfigFilePath)) "Failed to find config file";
	[xml]$deployConfig = [xml](Get-Content $deployConfigFilePath);
	
	switch ($targetEnvironment)
	{
		"DEVVM" {  $environmentGroup = "DEV"; break; }
		"BuildServer" {  $environmentGroup = "DEV"; break; }
		default {$environmentGroup = $targetEnvironment; break}
	}
}
#endregion

task default -Depends Display-EnvironmentInformation;

#####################################################################################################
# COMBINED TASKS
#####################################################################################################

	task Drop-All -Depends Drop-SQLAgentJobs, Drop-SSAS, Drop-SSIS, Drop-Databases {}

	task Build-All {

		# following builds main solution using msbuild.exe
		Build-Solution -SolutionName $SolutionName;
		
		# following builds SSIS solution using devenv.exe
		Build-BiSolution -SolutionName $SsisSolutionName;
		
		#Build-BiSolution -SolutionName $SsasSolutionName;
		#Build-BiSolution -SolutionName $SsrsSolutionName;
		
		if ($runFromVstsOrOctopus) 
		{
			Write-Host "BuildNumber set to: $buildNumber" -ForegroundColor Magenta;
			Write-Host "##vso[build.updatebuildnumber]$buildNumber";
		}
	}

	task Deploy-All -Depends Deploy-Databases, Deploy-SSIS, Deploy-SQLAgentJobs {} 

	task Run-Load {
		Start-SQLAgentJob -ServerRole "DWHServer" -JobName "Load_QuantumDM";
	}

#####################################################################################################
# Deployment Tasks
#####################################################################################################
	
	task Deploy-Databases { Deploy-SsdtSolutionDatabases -SolutionName $SolutionName; }
	
	task Deploy-QDM { Deploy-SsdtDatabase  -DatabaseName "DWH_QuantumDM" -SolutionName $SolutionName; }
	
	task Deploy-SSIS { 
        Deploy-SsisSolution -SolutionName $SsisSolutionName;	
        Deploy-SsisEnvironments -SolutionName $SsisSolutionName;
    }
	
	task Deploy-SSRS { 
		Deploy-SsrsSolutionUsingDevEnv -SolutionName $SolutionName;	
    }
	
	task Deploy-SSAS {
		Deploy-SsasSolution -SolutionName $SsasSolutionName;
	}

	task Process-SSAS {
		Process-SsasTabularDatabases -SolutionName $SsasSolutionName;
	}
	
    task Deploy-SQLAgentJobs {
		<# 
			.SYNOPSIS 
			Deploys all SQL Agent Jobs found in the $RootPath\SQLAgentJobs\$serverRole folder for each server role
		#>		
		foreach ($serverRole in $deployConfig.DeploymentConfig.ServerRoles.Role) {
            [string] $serverRoleName = $serverRole;
            if ($serverRoleName -ne "SSASServer") {
       		   
                $SQLCmdVaribles = Get-SqlCmdVariablesFromConfig -UseServerRoles $false;
                $ServerName = Get-DatabaseServerFromConfig -ServerRole $serverRole;

			    $scriptFolder = "$SqlScriptPath\SQLAgentJobs\$serverRole";

			    if (Test-Path $scriptFolder) {
				    Write-Host "Deploying SQL Agent Jobs to the $serverRole server $ServerName" -ForegroundColor Yellow;
			
				    # find all scripts in the folder				
				    $scripts = Get-ChildItem "$scriptFolder\*.sql";
				    foreach ($sqlFilePath in $scripts) {
					    Run-SqlScriptAgainstServer -ServerName $ServerName -DatabaseName "msdb" -SqlFilePath $sqlFilePath -SQLCmdVaribles $SQLCmdVaribles;
				    }
			    }
            }
		}
	}

#####################################################################################################
# Drop Tasks
#####################################################################################################
		
	task Drop-SQLAgentJobs {
		<# 
			.SYNOPSIS 
			Drop the SQL Agent Jobs 
		#>		
        $SQLCmdVaribles = Get-SqlCmdVariablesFromConfig -UseServerRoles $true;
        $ServerName = Get-DatabaseServerFromConfig -ServerRole "DWHServer";

		$sqlFilePath = "$SqlScriptPath\DropScripts\Drop_SQLAgent_Jobs.sql";
		if (Test-Path $sqlFilePath) {
			Run-SqlScriptAgainstServer -ServerName $ServerName -DatabaseName "msdb" -SqlFilePath $sqlFilePath -SQLCmdVaribles $SQLCmdVaribles;
        } else {
            Write-Host "Failed to find SQL Agent Drop Script $sqlFilePath" -ForegroundColor Red;
		}
	}
	
	task Drop-Databases { Drop-SsdtSolutionDatabases -SolutionName $SolutionName; }
	
	task Drop-SSIS { Drop-SsisFolder; }

	#task Drop-SSRS { Drop-SsrsFolder; }
	
	task Drop-SSAS { 
		Drop-SsasTabularSolution -SsasSolutionName $SsasSolutionName; 
	}
	
#####################################################################################################
# Pre-Deploy, Post-Deploy and Post-Load Scripts
#####################################################################################################
		
	task Run-PreDeployScripts {
		<# 
			.SYNOPSIS 
			Runs all scripts found in the Release_$ReleaseNumber\Databases\1_PreDeployScripts folder
			Note that these post-deploy scripts for a specific database are normally run by the 
			Deploy-SsdtDatabase function immediately before deploy.
		#>	
		Run-SqlScriptsInFolderOrder "$RootPath\Releases\Release_$ReleaseNumber\Databases\1_PreDeployScripts";
	}
	
	task Run-PostDeployScripts {
		<# 
			.SYNOPSIS 
			Runs all scripts found in the Release_$ReleaseNumber\Databases\2_PostDeployScripts folder
			Note that these post-deploy scripts for a specific database are normally run by the 
			Deploy-SsdtDatabase function immediately after deploy.
		#>	
		Run-SqlScriptsInFolderOrder "$RootPath\Releases\Release_$ReleaseNumber\Databases\2_PostDeployScripts";
	}

	task Run-PostLoadScripts {
		<# 
			.SYNOPSIS 
			Runs all scripts found in the Release_$ReleaseNumber\Databases\3_PostLoadScripts folder.
		#>	
		Run-SqlScriptsInFolderOrder "$RootPath\Releases\Release_$ReleaseNumber\Databases\3_PostLoadScripts";
	}

#####################################################################################################
# Apply end-user permissions
#####################################################################################################

	task Apply-UserPermissions { 
        ApplyUserPermissions-SsdtSolutionDatabases($SolutionName);	
        ApplyUserPermissions-SsasTabularSolutionDatabases($SsasSolutionName);	
    }
	


#####################################################################################################
# VSTS BUILD LOGGING FUNCTIONS
# See https://github.com/Microsoft/vsts-tasks/blob/master/docs/authoring/commands.md
#####################################################################################################
#region Logging functions
function logError ([string] $Message) {
    
	if ($runFromVstsOrOctopus)
	{
		$psake.build_success = $false;
		if ($Env:TF_BUILD)
		{
			#linenumber=1;columnnumber=1;code=100;
			[string] $curTaskName = "$($psake.context.Peek().currentTaskName)";
			[string] $logMsg = "##vso[task.logissue type=error;sourcepath=psakefile.ps1:$curTaskName;]$Message"
			Write-Error $logMsg;
			throw $logMsg;			
		}
		else
		{
			Write-Host "logError: $Message" -ForegroundColor Red;
			Write-Error "logError: $Message";
			exit 1;  # build_success not picked up by 
		}
	}
	else
	{
		Write-Host "logError: $Message" -ForegroundColor Red;
		Write-Error "logError: $Message";
	}
	$psake.build_success = $false;
}

function logWarning ([string] $Message) {
	if ($Env:TF_BUILD)
	{
		[string] $curTaskName = "$($psake.context.Peek().currentTaskName)";
		[string] $logMsg = "##vso[task.logissue type=warning;sourcepath=psakefile.ps1:$curTaskName;]$Message"
		Write-Host $logMsg;
	}
	else
	{
		Write-Host "WARNING: $Message" -ForegroundColor Cyan;
	}
}

function logInfo ([string] $Message) {
	Write-Host "INFO: $Message" -ForegroundColor Yellow;
}


function logComplete ([string] $Result) {  # $Result can have the values: Succeeded|SucceededWithIssues|Failed|Cancelled|Skipped
	if ($Env:TF_BUILD)
	{
		[string] $curTaskName = "$($psake.context.Peek().currentTaskName)";
		Write-Host "##vso[task.complete result=$Result;]$curTaskName";
	}
}
#endregion


#####################################################################################################
# RUN TESTS
#####################################################################################################
	task Run-UnitTests {
        $date = Get-Date -Format "yyyyMMdd";
	    $time = Get-Date -Format "HHmmss";
	    
        $testFolder = Join-Path $RootPath "Test";
        $testFiles = Get-ChildItem "$testFolder\*.UnitTests\bin\$configuration\*.UnitTests.dll";

        foreach ($testFile in $testFiles) {		
            $versionNumber = "$SprintNumber.$BuildNumber.$date.$time";
            $resultsFile = Split-Path $testFile -Leaf;
            $resultsFile = $resultsFile -replace ".dll", "";
            $resultsFile = Join-Path $TestResultsPath "$date.$time.$resultsFile.xml";
            #Write-Host $resultsFile
            RunTests -TestFilePath $testFile -ResultsFile $resultsFile;
            ParseTestResults -ResultsFile $resultsFile;
		}
    }

	task Update-UnitTestAppConfigs {
        $testFolder = Join-Path $RootPath "Test";
        $appConfigFiles = Get-ChildItem "$testFolder\*.UnitTests\bin\$configuration\*.UnitTests.dll.config";
		
		foreach ($appConfigFile in $appConfigFiles) {		
			[xml]$appConfig = [xml](Get-Content $appConfigFile);
				
			[string]$ConnectionString = $appConfig.configuration.SqlUnitTesting.ExecutionContext.ConnectionString;
			
			$ConnBuilder = New-Object System.Data.OleDb.OleDbConnectionStringBuilder($ConnectionString);
			$SourceDatabaseName = $ConnBuilder["Initial Catalog"];	
			$SourceServerName = Get-DatabaseServerNameFromConfig($SourceDatabaseName);			
            Write-Host "Updating $appConfigFile with new connection string pointing to $SourceServerName";
			$MappedDatabaseName = Get-MappedDatabaseNameFromConfig -DatabaseName $SourceDatabaseName;
			$ConnBuilder["Data Source"] = $SourceServerName;
			$ConnBuilder["Initial Catalog"] = $MappedDatabaseName;
			
			$appConfig.configuration.SqlUnitTesting.ExecutionContext.ConnectionString = $ConnBuilder.ConnectionString;
			$appConfig.configuration.SqlUnitTesting.PrivilegedContext.ConnectionString = $ConnBuilder.ConnectionString;
			
			$appConfig.Save($appConfigFile);
			#$SourceDatabaseName = Get-DatabaseServerNameFromConfig -DatabaseName $DatabaseName;

		}
	}

#####################################################################################################
# MISCELLANEOUS TASKS AND FUNCTIONS
#####################################################################################################
function test ($VALUE) {
	if ($VALUE) {
	     Write-Host -ForegroundColor GREEN “TRUE”
	} else {
		Write-Host -ForegroundColor RED   “FALSE”
	}
}

function Move-Folder ($sourceFolder, $folderName, $targetFolder) {
    if (Test-Path("$targetFolder/$folderName")) {
        Remove-Item "$targetFolder/$folderName" -Recurse;
    }
    Move-Item "$sourceFolder\$folderName" $targetFolder;
}


#region Display Environment Information

	task Display-EnvironmentInformation {
		<# 
			.SYNOPSIS 
			Display all environment information.
			Lists the servers and database names which everything would be deployed to
		#>
			
		Write-Host "PowerShell" (Get-Host | Select-Object Version);
		Write-Host "$UserName on $machineName";
        
		Write-Host;
		Write-Host "Root-Path = $RootPath";	
		Write-Host "PSake-Path = $BuildDirPath";
		Write-Host "CommonScriptsPath = $CommonScriptsPath";
		foreach ($script in $includeScripts) {
		[string]$scriptPath = Resolve-Path "$CommonScriptsPath\$script";
			Write-host "Included file: $scriptPath";
		}	
        Write-Host;
		Write-Host "Target Environment: $targetEnvironment" -ForegroundColor Yellow;
        Write-Host "TargetSQLServerInstance = $SQLServerInstance";
		Write-Host "ReleaseNumber = $ReleaseNumber";
        Write-Host "BuildNumber = $BuildNumber";
		Write-Host "Configuration = $configuration";
		Write-Host "TempPath = $TempPath";

		Write-Host;
		Write-Host "DatabaseSuffix=$databaseSuffix";

		Write-Host "Run Pre-Deploy Scripts = $runPreDeployScripts";
		Write-Host "Run Post-Deploy Scripts = $runPostDeployScripts";

		
        Write-Host;
		Write-Host "SQLCmdVariable Values" -ForegroundColor Yellow;		
		$SQLCmdVariables = Get-SqlCmdVariablesFromConfig($false);
		foreach ($variable in $SQLCmdVariables) {
            #[console]::CursorLeft = 4;
			Write-Host $variable
		}
		

		Write-Host;
		foreach ($solution in $deployConfig.DeploymentConfig.Solutions.Solution) {
			foreach ($database in $solution.Database) {
				[string] $DatabaseName = $database;
				[string] $ServerName = Get-DatabaseServerNameFromConfig($DatabaseName);
				$MappedDatabaseName = Get-MappedDatabaseNameFromConfig -DatabaseName $DatabaseName;
				$propertyValue = GetProperty-Database -DatabaseName $DatabaseName -PropertyName "NeverDeployDropOrRestore" -Default "False"
                #[console]::CursorLeft = 4;
				if ($propertyValue -eq "True") {
					Write-Host "Would NOT deploy $DatabaseName database to $ServerName.$MappedDatabaseName as NeverDeployDropOrRestore='True'. Please create database change script using the .\psake.ps1 Script-XXX command" -BackgroundColor Yellow -ForegroundColor Black;
				} else {
					Write-Host "Would deploy $DatabaseName database to $ServerName.$MappedDatabaseName";
				}
			}
			
			foreach ($database in $solution.SSAS_Tabular) {
				[string] $DatabaseName = $database.Project;
				[string] $ServerName = Get-AnalysisServicesServerFromConfig;
				$MappedDatabaseName = Get-MappedDatabaseNameFromConfig -DatabaseName $DatabaseName;
				Write-Host "Would deploy $DatabaseName database to $ServerName.$MappedDatabaseName";
			}
		}

		DisplayExePaths;		

        Write-Host;
        Write-Host "To list all valid Tasks, type";
        #[console]::CursorLeft = 4;
        Write-Host ".\psake.ps1 Get-Help" -ForegroundColor Yellow;
        Write-Host "at the command prompt";
	}

#endregion

#region Clean Up Tasks
	task Clean-Projects {
		<# 
			.SYNOPSIS 
			Removes all build artefacts from the folder structure
		#>
    
        try {
	        cd $RootPath;

		    logInfo -Message "Removing all 'bin' and 'obj' folders";
		    $folders = Get-ChildItem -Path "bin" -recurse;
		    foreach ($folder in $folders) {
			    Write-Host "Removing $folder";
                Remove-Item -Path $folder  -recurse;
		    }

            $folders = Get-ChildItem -Path "obj" -recurse;
		    foreach ($folder in $folders) {
			    Write-Host "Removing $folder";
                Remove-Item -Path $folder  -recurse;
		    }

		    logInfo -Message "Removing all 'dbmdl' files";
		    $folders = Get-ChildItem -Path "*.dbmdl" -recurse;
		    foreach ($folder in $folders) {
			    Write-Host "Removing $folder";
                Remove-Item -Path $folder  -recurse;
		    }

            logInfo -Message "Removing everything from temp directory";
            cd $TempPath;
		    Remove-Item -Path "*.*" -recurse;
        } catch {
        	logError -Message "Failed to run task Clean-Projects $_";
        }
	}
#endregion

#region TFS tasks 

	task Get-TfsLatest {
		exec { &"$TfPath" get "$RootPath" /recursive; }
	}

	function Check-TfsStatus {
		if ($runFromVstsOrOctopus) 
		{
			logInfo -Message "Running from build server. Check-TfsStatus ignored";
			return $true;
		}
		else
		{
			$returnValue = (&"$TfPath" status "$RootPath" /recursive);
			if ($returnValue -eq "There are no pending changes.") {
				return $true;
			} else {
				return $false;
			}
		}
	}
#endregion 

#region Get-Help
	task Get-Help {
        # get content of this powershell and find all instances of the word task in this file
        $tasks = Get-Content -Path "$BuildDirPath\default.ps1" | Select-String "\ttask " | Sort-Object;
        $prevTaskGroup = "";
        foreach ($task in $tasks) {     
        #Write-Host $task;
            $task = $task -replace "\ttask ", ""
            $task = $task -replace "{", ""
            $task = $task.substring(0,$task.indexof(" "))
            $taskGroup = $task.substring(0,$task.indexof("-"))
            if ($prevTaskGroup -ne $taskGroup) {
                Write-Host;
                Write-Host "$taskGroup Tasks" -ForegroundColor Yellow;
                $prevTaskGroup = $taskGroup;
            }
            Write-Host $task;
        }
    }
#endregion

#region Get-SqlCmdVariablesFromConfig
	function Get-SqlCmdVariablesFromConfig ([bool] $UseServerRoles = $(throw "Must set UseServerRoles")) {
		# First create a SQLCmd variable list from the deployment config file which all scripts will use
		$SQLCmdVaribles = @();
		
		$SQLCmdVaribles += "EnvironmentName=$targetEnvironment";
		$SQLCmdVaribles += "EnvironmentGroup=$environmentGroup";
        $SQLCmdVaribles += "BuildNumber=$BuildNumber";
        $SQLCmdVaribles += "UserName=$UserName";

        # add SSIS deployment variables
		$solutionNode = $deployConfig.DeploymentConfig.Solutions.Solution | where Name -EQ $SsisSolutionName;
		foreach ($project in $solutionNode.SSIS_Project) {
		    $SQLCmdVaribles += "SsisDbProjectName=$($project.Project)";
            $SQLCmdVaribles += "SsisDbFolderName=$($project.Folder)";
			$SQLCmdVaribles += "SsisDbEnvironmentName=$($project.Environment)";
        }
		$SQLCmdVaribles += "SsisCredentialName=$SsisCredentialName";
		$SQLCmdVaribles += "SsisProxyName=$SsisProxyName";
		$SQLCmdVaribles += "SsasCredentialName=$SsasCredentialName";
		$SQLCmdVaribles += "SsasProxyName=$SsasProxyName";
		$SQLCmdVaribles += "QDMOperatorName=$QDMOperatorName";
		$SQLCmdVaribles += "QDMOperatorEmail=$QDMOperatorEmail";
		$SQLCmdVaribles += "JobCategory=$JobCategory";
		$SQLCmdVaribles += "DomainName=$DomainName";

		foreach ($database in $deployConfig.DeploymentConfig.Databases.Database) {
			$DatabaseName = $database.GetAttribute("name");
			$MappedDatabaseName = Get-MappedDatabaseNameFromConfig -DatabaseName $DatabaseName;
			if ($UseServerRoles) {
				$ServerName = Get-DatabaseServerRoleFromConfig($DatabaseName);
			} else {
				$ServerName = Get-DatabaseServerNameFromConfig($DatabaseName);
			}
				
			# IMPORTANT: Do not add spaces or single quotes to the SQLCmd variables otherwise they are not recognized!
			$SQLCmdVaribles += "$DatabaseName=$MappedDatabaseName";
			$SQLCmdVaribles += $DatabaseName + "Server=$ServerName";
		}
		
		foreach ($serverRole in $deployConfig.DeploymentConfig.ServerRoles.Role) {
			$ServerName = Get-DatabaseServerFromConfig($serverRole);
				
			# IMPORTANT: Do not add spaces or single quotes to the SQLCmd variables otherwise they are not recognized!
			$SQLCmdVaribles += "$serverRole=$ServerName";			
		}
		
		

		# add all the SqlCmdVariables from config
		$targetEnvNode = GetTargetEnviromentNode;
		foreach ($variable in $targetEnvNode.SQLCmdVariables.SQLCmdVariable) {
			$variableName = $variable.GetAttribute("Include");
			$variableValue = $variable.Value;
			# IMPORTANT: Do not add spaces or single quotes to the SQLCmd variables otherwise they are not recognized!
			# Also, do not try to add entire connection strings as they contain equal signs which screw it all up
			$SQLCmdVaribles += "$variableName=$variableValue";
		}


		# output the variable pairs if we are in debug mode
		foreach ($variable in $SQLCmdVaribles) {
			Write-Debug $variable;
		}
		return $SQLCmdVaribles;
	}
#endregion
