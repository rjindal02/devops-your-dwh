#####################################################################################################
# Script written by © Dr. John Tunnicliffe, 2015-2018 https://github.com/DrJohnT/devops-your-dwh
# This PowerShell script is released under the MIT license http://www.opensource.org/licenses/MIT
#
# SSDT database Functions
##############################################################################################

	function Deploy-SsdtSolutionDatabases ([string] $SolutionName = $(throw "SolutionName is required!")) {
		<# 
			.SYNOPSIS 
			Deploys all the SSDT databases that are in a SSDT solution as defined in the Config.xml (not the actual solution file!)
		#>			
		$solutionNode = $deployConfig.DeploymentConfig.Solutions.Solution | where Name -EQ $SolutionName;
		foreach ($database in $solutionNode.Database) {		
			Deploy-SsdtDatabase -DatabaseName $database -SolutionName $SolutionName;
		}
	}

	function Deploy-SsdtDatabase ([string] $DatabaseName =  $(throw "Database name required."), 
		[string] $SolutionName = $(throw "Solution name required.")) {
		<# 
			.SYNOPSIS 
			Checks if the database should be deployed based on the NeverDeployDropOrRestore flag.
			If so, deploy the DACPAC by calling Deploy-SsdtDatabaseNoChecks
		#>			
		$propertyValue = GetProperty-Database -DatabaseName $DatabaseName -PropertyName "NeverDeployDropOrRestore" -Default "False"
		if ($propertyValue -eq "True") { 
			Write-Host "$DatabaseName database will not be deployed. Please deploy manually" -BackgroundColor Yellow -ForegroundColor Black; 
			return 
		}

		$propertyValue = GetProperty-Database -DatabaseName $DatabaseName -PropertyName "NeverDeploy" -Default "False"
		if ($propertyValue -eq "True") { 
			Write-Host "$DatabaseName database will not be deployed. Please deploy manually" -BackgroundColor Yellow -ForegroundColor Black; 
			return 
		}
		
		assert(Test-Path($SqlPackageExePath)) "SqlPackage must be available!"
		
		$createNewDB = GetProperty-AlwaysCreateNewDatabase -DatabaseName $DatabaseName;
		if ($createNewDB -EQ "True") {
			Drop-SsdtDatabase -DatabaseName $DatabaseName;
		} 
		
		Deploy-SsdtDatabaseNoChecks -DatabaseName $DatabaseName -SolutionName $SolutionName;
	}
	
	function Get-DacPackPath([string] $SolutionName = $(throw "Solution name required."),
			[string] $DatabaseName = $(throw "Database name required.")) {
		# returns the path to the project DACPAC
		$SolutionPath = Get-SolutionPath($SolutionName);
		$SolutionFolderPath = Split-Path $SolutionPath;
		$sourceDacPacPath = "$SolutionFolderPath\Databases\$DatabaseName\bin\$configuration\$DatabaseName.dacpac";
		assert(Test-Path($sourceDacPacPath)) "DACPAC must exist in $sourceDacPacPath";
		return $sourceDacPacPath;
	}
	
	function Deploy-SsdtDatabaseNoChecks ([string] $DatabaseName =  $(throw "Database name required."), 
		[string] $SolutionName = $(throw "Solution name required.")) {
		<# 
			.SYNOPSIS 
			Deploy the DACPAC using a DAC Publish profile created on the fly by Create-DacPublishProfile
			If AlwaysCreateNewDatabase = True then we drop the database before deploying.
			
			Prior to deployment, the function also runs any pre-deployment scripts
			
			After deployment, the function also calls
				Apply-UserPermissions
				Runs any post-deploy scripts
		#>			
		
		$createNewDB = GetProperty-AlwaysCreateNewDatabase -DatabaseName $DatabaseName;
        
        $MappedDatabaseName = Get-MappedDatabaseNameFromConfig -DatabaseName $DatabaseName;

        if ($DatabaseName -ne $MappedDatabaseName)
        {
            # alter the app.config of the unit tests

        }

		if ($createNewDB -EQ "True") {
			Write-Host "Deploying database '$MappedDatabaseName'"  -ForegroundColor Yellow;
		} else {
			# Run all pre-deploy scripts on the database (if any)
            if ($runPreDeployScripts) {
			    Write-Host("Running pre-deploy scripts for database '$MappedDatabaseName'");
			    Run-SqlScriptsForSpecificDatabase -SqlFolderPath "$RootPath\Releases\Release_$ReleaseNumber\Databases\1_PreDeployScripts" -DatabaseName $DatabaseName;
			} else {
                logInfo -Message "WARNING: Release specific pre-deploy scripts for database $DatabaseName will NOT be run as variable `$runPreDeployScripts=`$false";
            }
			Write-Host "Performing incremental upgrade to database '$MappedDatabaseName'" -ForegroundColor Yellow;
		}
		
		$ServerName = Get-DatabaseServerNameFromConfig($DatabaseName);
		
		$sourceDacPacPath = Get-DacPackPath -SolutionName $SolutionName -DatabaseName $DatabaseName;
		
		$configFilePath = Create-DacPublishProfile -DatabaseName $DatabaseName -ServerName $ServerName;
        #Write-Host "$SqlPackageExePath" /Action:Publish /SourceFile:"$sourceDacPacPath" /Profile:"$configFilePath"
         
        $logFilePath = "$TempPath\$SolutionName.$DatabaseName.log"
        #Out-File -FilePath "$logFilePath"  
        #Tee-Object -FilePath "$logFilePath"
        try {
		    exec { &"$SqlPackageExePath" /Action:Publish /SourceFile:"$sourceDacPacPath" /Profile:"$configFilePath" | Out-File -FilePath "$logFilePath" } 
		} catch {            
			$buildlog = Get-Content($logFilePath);
			Write-Host($buildlog);
			logError -Message "Deploy-SsdtDatabaseNoChecks Failed to deploy database $DatabaseName Error: $_";
		}
		# apply the user permission post-deploy scripts to all environments except LOCAL
		ApplyUserPermissionsToDatabase -DatabaseName $DatabaseName;

        # run any post-deploy scripts
		Write-Host("Running post-deploy scripts for database '$DatabaseName'");
		Run-SqlScriptsForSpecificDatabase -SqlFolderPath "$SqlScriptPath\PostDeploymentScripts" -DatabaseName $DatabaseName;
        if ($runPostDeployScripts) {
		    Run-SqlScriptsForSpecificDatabase -SqlFolderPath "$RootPath\Releases\Release_$ReleaseNumber\Databases\2_PostDeployScripts" -DatabaseName $DatabaseName;
		} else {
            logInfo -Message "WARNING: Release specific post-deploy scripts for database $DatabaseName will NOT be run as variable `$runPostDeployScripts=`$false";
        }
        
	}
	
	function Create-DacPublishProfile ([string] $DatabaseName, [string] $ServerName) {
		<# 
			.SYNOPSIS 
			Create a new DAC Publish config file in the ~\BuildDeployScripts\Temp folder.
		#>			
		$configPath = Join-Path $TempPath "$DatabaseName.publish.xml";
		
		if (Test-Path $configPath) {
			Remove-Item $configPath;
		}
		
		$MappedDatabaseName = Get-MappedDatabaseNameFromConfig -DatabaseName $DatabaseName;
		
		# Create The Document
		$xmlWriter = New-Object System.XMl.XmlTextWriter($configPath,$Null);
	 
		# Set The Formatting
		$xmlWriter.Formatting = "Indented";
		$xmlWriter.Indentation = "4";
	 
		# Write the XML Decleration
		$xmlWriter.WriteStartDocument();
		$xmlWriter.WriteStartElement("Project");
		
		$xmlWriter.WriteAttributeString("ToolsVersion", "4.0");
		$xmlWriter.WriteAttributeString("xmlns", "http://schemas.microsoft.com/developer/msbuild/2003");

			$xmlWriter.WriteStartElement("PropertyGroup");
			
				[string] $propertyValue = GetProperty-AlwaysCreateNewDatabase -DatabaseName $DatabaseName;				
				$xmlWriter.WriteElementString("AlwaysCreateNewDatabase", $propertyValue);
				$xmlWriter.WriteElementString("IncludeCompositeObjects", "True");
				
				# change target database name to include $databaseSuffix
				$xmlWriter.WriteElementString("TargetDatabaseName", "$MappedDatabaseName");
				$xmlWriter.WriteElementString("DeployScriptFileName", "$MappedDatabaseName.sql");
				
				# set some standard deployment options
				$xmlWriter.WriteElementString("RegisterDataTierApplication", "True");
				$xmlWriter.WriteElementString("BlockWhenDriftDetected", "False");
				$xmlWriter.WriteElementString("GenerateSmartDefaults", "True");  
				$propertyValue = GetProperty-Database -DatabaseName $DatabaseName -PropertyName "BlockOnPossibleDataLoss" -Default "False"
				$xmlWriter.WriteElementString("BlockOnPossibleDataLoss", $propertyValue);
				$xmlWriter.WriteElementString("ProfileVersionNumber", "1");
				
				# drop objects not in source except for extended properties.  Ignore security stuff
				$propertyValue = GetProperty-Database -DatabaseName $DatabaseName -PropertyName "DropObjectsNotInSource" -Default "True"
				$xmlWriter.WriteElementString("DropObjectsNotInSource", $propertyValue); 
				
				$xmlWriter.WriteElementString("DropExtendedPropertiesNotInSource", "False");
				$xmlWriter.WriteElementString("DoNotDropExtendedProperties", "True");
				$xmlWriter.WriteElementString("DoNotDropLogins", "True");
				$xmlWriter.WriteElementString("DoNotDropUsers", "True");
				$xmlWriter.WriteElementString("DoNotDropRoleMembership", "True");
				$xmlWriter.WriteElementString("DoNotDropApplicationRoles", "True");
				$xmlWriter.WriteElementString("DoNotDropDatabaseRoles", "True");
				$xmlWriter.WriteElementString("DoNotDropPermissions", "True");

                # See following blog entry for why we need ScriptFileSize = True for server deployments
                # http://scotta-businessintelligence.blogspot.co.uk/2013/12/database-deployments-with-ssdtdata-file.html
                if ($targetEnvironment -eq "LOCAL") {
                    $xmlWriter.WriteElementString("ScriptFileSize", "False"); 
                } else {
                    $xmlWriter.WriteElementString("ScriptFileSize", "True"); 
                }

				#$xmlWriter.WriteElementString("IgnoreTableOptions", "True"); # does not seem to work
				
				# https://msdn.microsoft.com/en-us/library/hh550081(v=vs.103).aspx
				#$xmlWriter.WriteElementString("DacVersion", "$buildNumber");
				#$xmlWriter.WriteElementString("DacApplicationDescription", "Deployed by $username");
				
				# set connection string to target server
				$connBuilder = New-Object System.Data.OleDb.OleDbConnectionStringBuilder;
				$connBuilder["Data Source"] = $ServerName;
				$connBuilder["Integrated Security"] = "True";
				$xmlWriter.WriteElementString("TargetConnectionString", $connBuilder.ConnectionString);
			
			# close the "PropertyGroup" node:
			$xmlWriter.WriteEndElement()	
			
			# write all SQLCmd variables
			$xmlWriter.WriteStartElement("ItemGroup");
				$SQLCmdVaribles = Get-SqlCmdVariablesFromConfig($false);
				foreach ($SQLCmdVarible in $SQLCmdVaribles)
				{
					$SQLCmdVariblePart = $SQLCmdVarible.Split("=");
					$xmlWriter.WriteStartElement("SqlCmdVariable");
						$xmlWriter.WriteAttributeString("Include", $SQLCmdVariblePart[0]);
						$xmlWriter.WriteElementString("Value", $SQLCmdVariblePart[1]);
					$xmlWriter.WriteEndElement();				
				}

			# close the "ItemGroup" node:
			$xmlWriter.WriteEndElement();
		
		# close the "Project" node:
		$xmlWriter.WriteEndElement();
		 
		# finalize the document:
		$xmlWriter.WriteEndDocument();
		$xmlWriter.Flush();
		$xmlWriter.Close();
		return $configPath;
	}	


	function Drop-SsdtSolutionDatabases ([string] $SolutionName = $(throw "SolutionName is required!")) {
		<#
			.SYNOPSIS
			Drops all databases in the solution.
		#>		
		$solutionNode = $deployConfig.DeploymentConfig.Solutions.Solution | where Name -EQ $SolutionName;
		foreach ($database in $solutionNode.Database) {		
			Drop-SsdtDatabase -DatabaseName $database;
		}
	}

	function Drop-SsdtDatabase([string] $DatabaseName = $(throw "Database name required.")) {
		<#
			.SYNOPSIS
			Drops the database. 
			For safety, only databases with NeverDeployDropOrRestore="False" will be dropped
		#>	
		$propertyValue = GetProperty-Database -DatabaseName $DatabaseName -PropertyName "NeverDeployDropOrRestore" -Default "False"
		if ($propertyValue -eq "True") { 
			Write-Host "$DatabaseName database will not be dropped. Please drop manually." -BackgroundColor Yellow -ForegroundColor Black; 
			return 
		}
		$propertyValue = GetProperty-Database -DatabaseName $DatabaseName -PropertyName "NeverDrop" -Default "False"
		if ($propertyValue -eq "True") { 
			Write-Host "$DatabaseName database will not be dropped. Please drop manually." -BackgroundColor Yellow -ForegroundColor Black; 
			return 
		}
		Drop-SsdtDatabaseNoChecks -DatabaseName $DatabaseName;
	}
	
	function Drop-SsdtDatabaseNoChecks([string] $DatabaseName = $(throw "Database name required.")) {
		<#
			.SYNOPSIS
			Drops the database regardless of the NeverDeployDropOrRestore flag
		#>	
		try {
			$ServerName = Get-DatabaseServerNameFromConfig($DatabaseName);
			
			# add the suffix as that is the database we are dropping
			$MappedDatabaseName = Get-MappedDatabaseNameFromConfig -DatabaseName $DatabaseName;
	  	    
            if (DoesDatabaseExist -ServerName $ServerName -DatabaseName $MappedDatabaseName)			
			{
				# Kill database will drop active connections before dropping the database
        		[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SMO") | Out-Null;
		        $server = New-Object -TypeName Microsoft.SqlServer.Management.Smo.Server -ArgumentList $ServerName;
                $server.KillDatabase($MappedDatabaseName);
                Write-Host("Dropped database $MappedDatabaseName on $ServerName");
				
			}
		} catch {
			logError -Message "Drop-SsdtDatabaseNoChecks Failed to deploy database $DatabaseName Error: $_";
		}
	}	
