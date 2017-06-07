<#-------------Create Deployment Start------------------#>
Import-Module .\TestLibs\RDFELibs.psm1 -Force
$result = ""
$testResult = ""
$resultArr = @()
$isDeployed = DeployVMS -setupType $currentTestData.setupType -Distro $Distro -xmlConfig $xmlConfig
if ($isDeployed)
{
	try
	{
		$noClient = $true
		$noServer = $true
		foreach ( $vmData in $allVMData )
		{
			if ( $vmData.RoleName -imatch "client" )
			{
				$clientVMData = $vmData
				$noClient = $false
			}
			elseif ( $vmData.RoleName -imatch "server" )
			{
				$noServer = $fase
				$serverVMData = $vmData
			}
		}
		if ( $noClient )
		{
			Throw "No any master VM defined. Be sure that, Client VM role name matches with the pattern `"*master*`". Aborting Test."
		}
		if ( $noServer )
		{
			Throw "No any slave VM defined. Be sure that, Server machine role names matches with pattern `"*slave*`" Aborting Test."
		}
		#region CONFIGURE VM FOR TERASORT TEST
		LogMsg "CLIENT VM details :"
		LogMsg "  RoleName : $($clientVMData.RoleName)"
		LogMsg "  Public IP : $($clientVMData.PublicIP)"
		LogMsg "  SSH Port : $($clientVMData.SSHPort)"
		LogMsg "SERVER VM details :"
		LogMsg "  RoleName : $($serverVMData.RoleName)"
		LogMsg "  Public IP : $($serverVMData.PublicIP)"
		LogMsg "  SSH Port : $($serverVMData.SSHPort)"

		#
		# PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.	
		#
		ProvisionVMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"

		#endregion

		LogMsg "Generating constansts.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
		Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile	
		Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
		foreach ( $param in $currentTestData.TestParameters.param)
		{
			Add-Content -Value "$param" -Path $constantsFile
		}
		LogMsg "constanst.sh created successfully..."
		LogMsg (Get-Content -Path $constantsFile)
		#endregion

		
		#region EXECUTE TEST
		$myString = @"
cd /root/
./perf_ntttcp.sh &> ntttcpConsoleLogs.txt
. azuremodules.sh
collect_VM_properties
"@
		Set-Content "$LogDir\StartNtttcpTest.sh" $myString
		RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files ".\$constantsFile,.\remote-scripts\azuremodules.sh,.\remote-scripts\perf_ntttcp.sh,.\$LogDir\StartNtttcpTest.sh" -username "root" -password $password -upload
		RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files $currentTestData.files -username "root" -password $password -upload

		$out = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
		$testJob = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/StartNtttcpTest.sh" -RunInBackground
		#endregion

		#region MONITOR TEST
		while ( (Get-Job -Id $testJob).State -eq "Running" )
		{
			$currentStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -5 ntttcpConsoleLogs.txt | head -1"
			LogMsg "Current Test Staus : $currentStatus"
			WaitFor -seconds 20
		}
		$finalStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/ntttcpConsoleLogs.txt"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "lagscope-ntttcp-*"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "ntttcp-p*"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "report.log"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"
		
		$testSummary = $null
		$ntttcpReportLog = Get-Content -Path "$LogDir\report.log"
		foreach ( $line in $ntttcpReportLog )
		{
            if ( $line -imatch "test_connections" )
            {
                continue;
            }
            try
            {
                $test_connections = $line.Trim().Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Split(" ")[0]
                $throughput_gbps = $line.Trim().Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Split(" ")[1]
                $average_tcp_latency = $line.Trim().Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Replace("  "," ").Split(" ")[2]
                $metadata = "Connections=$test_connections"
                $connResult = "throughput=$throughput_gbps`Gbps Avg_TCP_lat=$average_tcp_latency"
                $resultSummary +=  CreateResultSummary -testResult $connResult -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            }
            catch
            {
                $resultSummary +=  CreateResultSummary -testResult "Error in parsing logs." -metaData "NTTTCP" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
            }
		}
		#endregion

		if ( $finalStatus -imatch "TestFailed")
		{
			LogErr "Test failed. Last known status : $currentStatus."
			$testResult = "FAIL"
		}
		elseif ( $finalStatus -imatch "TestAborted")
		{
			LogErr "Test Aborted. Last known status : $currentStatus."
			$testResult = "ABORTED"
		}
		elseif ( $finalStatus -imatch "TestCompleted")
		{
			LogMsg "Test Completed."
			$testResult = "PASS"
		}
		elseif ( $finalStatus -imatch "TestRunning")
		{
			LogMsg "Powershell backgroud job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
			LogMsg "Contests of summary.log : $testSummary"
			$testResult = "PASS"
		}
		LogMsg "Test result : $testResult"
		LogMsg "Test Completed"
		
		LogMsg "Uploading the test results.."
		$dataSource = $xmlConfig.config.Azure.database.server
		$user = $xmlConfig.config.Azure.database.user
		$password = $xmlConfig.config.Azure.database.password
		$database = $xmlConfig.config.Azure.database.dbname
		$dataTableName = $xmlConfig.config.Azure.database.dbtable
		$TestCaseName = $xmlConfig.config.Azure.database.testTag
		if ($dataSource -And $user -And $password -And $database -And $dataTableName) 
		{
			$GuestDistro	= cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
			
			#$TestCaseName	= "LINUX-NEXT-UPSTREAM-TEST"
			if ( $UseAzureResourceManager )
			{
				$HostType	= "Azure-ARM"
			}
			else
			{
				$HostType	= "Azure"
			}
			$HostBy	= ($xmlConfig.config.Azure.General.Location).Replace('"','')
			$HostOS	= cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
			$GuestOSType	= "Linux"
			$GuestDistro	= cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
			$GuestSize = $clientVMData.InstanceSize
			$KernelVersion	= cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}
			$IPVersion = "IPv4"
			$ProtocolType = "TCP"
			if($EnableAcceleratedNetworking)
			{
				$DataPath = "SRIOV"
			}
			else
			{
				$DataPath = "Synthetic"    
			}
			$connectionString = "Server=$dataSource;uid=$user; pwd=$password;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
			$LogContents = Get-Content -Path "$LogDir\report.log"
			$SQLQuery = "INSERT INTO $dataTableName (TestCaseName,TestDate,HostType,HostBy,HostOS,GuestOSType,GuestDistro,GuestSize,KernelVersion,IPVersion,ProtocolType,DataPath,NumberOfConnections,Throughput_Gbps,Latency_ms) VALUES "

			for($i = 1; $i -lt $LogContents.Count; $i++)
			{
				$Line = $LogContents[$i].Trim() -split '\s+'
				$SQLQuery += "('$TestCaseName','$(Get-Date -Format yyyy-MM-dd)','$HostType','$HostBy','$HostOS','$GuestOSType','$GuestDistro','$GuestSize','$KernelVersion','$IPVersion','$ProtocolType','$DataPath',$($Line[0]),$($Line[1]),$($Line[2])),"
			}
			$SQLQuery = $SQLQuery.TrimEnd(',')
			LogMsg $SQLQuery
			$connection = New-Object System.Data.SqlClient.SqlConnection
			$connection.ConnectionString = $connectionString
			$connection.Open()

			$command = $connection.CreateCommand()
			$command.CommandText = $SQLQuery
			$result = $command.executenonquery()
			$connection.Close()
			LogMsg "Uploading the test results done!!"
		}
		else
		{
			LogMsg "Invalid database details. Failed to upload result to database!"
		}
	}
	catch
	{
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"   
	}
	Finally
	{
		$metaData = "NTTTCP RESULT"
		if (!$testResult)
		{
			$testResult = "Aborted"
		}
		$resultArr += $testResult
	}   
}

else
{
	$testResult = "Aborted"
	$resultArr += $testResult
}

$result = GetFinalResultHeader -resultarr $resultArr

#Clean up the setup
DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed -ResourceGroups $isDeployed

#Return the result and summery to the test suite script..
return $result, $resultSummary
