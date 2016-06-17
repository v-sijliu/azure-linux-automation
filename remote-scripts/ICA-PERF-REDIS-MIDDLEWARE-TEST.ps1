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
		Set-Content -Value "/root/perf_redis.sh &> redisConsoleLogs.txt" -Path "$LogDir\StartRedisTest.sh"
		RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files ".\$constantsFile,.\remote-scripts\perf_redis.sh,.\$LogDir\StartRedisTest.sh" -username "root" -password $password -upload

		$out = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
		$testJob = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/StartRedisTest.sh" -RunInBackground
		#endregion

		#region MONITOR TEST
		while ( (Get-Job -Id $testJob).State -eq "Running" )
		{
			$currentStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -n 1 /root/redisTest.log"
			LogMsg "Current Test Staus : $currentStatus"
			WaitFor -seconds 20
		}
		
		$finalStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
		
		$finalStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/redisConsoleLogs.txt"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/redisTest.log"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "redis-server-pipelines-*"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "redis-client-pipelines-*"
		
		$testSummary = $null
		$redisLogFiles = Get-ChildItem -Path $LogDir | Select Name | where { ( $_ -imatch "redis-server-pipelines") -or ( $_ -imatch "redis-client-pipelines") }
		foreach ( $file in $redisLogFiles )
		{
			LogMsg "$($file.Name) downloaded."
		}

		$redisClientLogFiles = Get-ChildItem -Path $LogDir | Select Name | where {($_ -imatch "redis-client-pipelines") -and ( $_ -imatch "set.get.log")}
		$resultSummary = $null
		foreach ( $file in $redisClientLogFiles )
		{
			$connResult = $null
			$testType = $null
			$testTypeResult = $null
			foreach ( $line in $clientTxt ) 
			{ 
				if ( $line -imatch "SET:")
				{
					$testType = "SET"
				}
				if ( $line -imatch "GET:")
				{
					$testType = "GET"
				}
				if ( $line -imatch "requests per second" )
				{
					$testTypeResult = $line
				}
				if ( $testTypeResult -and $testType)
				{
					if ( $connResult )
					{
						$connResult += "," + $testType + " " + $line
					}
					else
					{
						$connResult = $testType + " " + $line
					}
					$testType = $null
					$testTypeResult = $null
				}
			}
			$metadata = $($file.Name).Replace("redis-client-","").Replace(".set.get.log","").Replace("-","=")
			if ( $connResult )
			{
				$resultSummary +=  CreateResultSummary -testResult $connResult -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
			}
			else
			{
				$resultSummary +=  CreateResultSummary -testResult "EROR: No result matching strings found. Possible Test Error." -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
			}
			LogMsg "Analysed $($file.Name) for number of requests."
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
			LogMsg "Powershell backgroud job for test is completed but VM is reporting that test is still running. Please check $LogDir\redisConsoleLogs.txt"
			LogMsg "Contests of state.txt : $finalStatus"
			$testResult = "PASS"
		}
		LogMsg "Test result : $testResult"
		LogMsg "Test Completed"
	}
	catch
	{
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"   
	}
	Finally
	{
		$metaData = "REDIS RESULT"
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
