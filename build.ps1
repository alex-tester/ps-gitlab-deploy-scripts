<#
REQUIRES invoke-msbuild module
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    $Tasks,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateSet("powershell", "netclassic", "netcore", "html", "genericcopy", "powershellmodule", "netcore-k8s")]
    $ProjectType,
    $deploylocations,
    [ValidateSet("prod", "qa", "test")]
    $environment,
    $DeploymentUsername,
    $DeploymentPassword,
    $DockerUsername,
    $DockerPassword,
    $RegistryUsername,
    $RegistryPassword,
    $DeploymentSourceRoot = "./",
    $TempBuildLocation,
    $ContainerRegistryUrl,
    $ProjectName,
    $DockerBuildServer,
    $KubernetesCluster,
    $CommitSHA

)

$ObservicingCertificatePfx = "removed" #need to make this dynamic so other certs can be used

#CI_PROJECT_NAME - gitlab variable for project name
#CI_REGISTRY_IMAGE url to specifix project registry
Write-Output ""
write-output "Starting deploy script build.ps1"
$workingdir = (get-location).path
write-output "Working Directory: $workingdir"
write-output "Number of tasks specified: $($tasks.count)"
write-output " "
write-output "Input Parameters:"
write-output "Tasks: $tasks"
Write-Output "Project Name: $ProjectName"
Write-Output "ProjectType: $projecttype"
write-output "DeployLocations: $deploylocations"
write-output "Environment: $environment"
write-output "Temp Build Location: $tempbuildlocation"
write-output " "

if ($ProjectType -eq "netcore-k8s")
{
    Write-Output "Docker Build Server: $DockerBuildServer"
    Write-Output "Kubernetes Cluster: $KubernetesCluster"
    #Write-Output "Project Name: $ProjectName"
    Write-Output "Container Registry Url: $ContainerRegistryUrl"
    Write-Output "Commit SHA: $CommitSHA"
    #Write-Output "Target Branch SHA: $TargetBranchSHA"
    #Write-Output "Soutce Branch SHA: $SourceBranchSHA"
    Write-Output ""
}
#Reset error count
$error.clear()

#Master project type list
$projecttypesavailable = @("powershell", "netclassic", "netcore", "html", "genericcopy", "powershellmodule", "netcore-k8s")

#Target locations per environment - split locations by ,
if ($deploylocations)
{
    $targetlocations = @()
    foreach ($location in ($deploylocations.split(",")))
    {
        $targetlocations += $location
    }
}




#Split tasks by ,
$tasks = $tasks.split(",")
$taskstodo = @()
write-output "Tasks: "
foreach ($item in $tasks)
{
    $taskstodo += $item
    write-output "- $item"
}



function Get-GitCommitMessage
{
    $message = git log -1 --pretty=%B
    #merge into 1 line
    [string]$outputmessage = ""
    foreach ($item in $message)
    {
        $outputmessage += "$item "
    }
    $outputmessage = $outputmessage.Substring(0, $outputmessage.length - 1)

    return $outputmessage
}

function invoke-notasksmatched
{
    param(
        $tasks,
        $projecttype,
        $environment,
        $deploylocations
    )

    write-output "No task names matched... Skipping deploy... setting exit1 to true"
    write-output "Inputs were:"
    write-output "- Tasks: $tasks"
    write-output "- ProjectType: $projecttype"
    write-output "- Environment: $environment"
    write-output "- DeployLocations: $deploylocations"
    $exit1 = $true
    return $exit1
}

function New-ObsCredentialObject
{
    param(
        $username,
        $password
    )

    $SecurePassword = $password | ConvertTo-SecureString -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($UserName,$SecurePassword)

    return $cred

}
function invoke-notprojecttypesmatched
{
    param(
        $tasks,
        $projecttype,
        $environment,
        $deploylocations
    )

    write-output "No project types were matched (powershell, netcore etc.)... Skipping deploy... setting exit1 to true"
    write-output "Project types supported by this deployment script are: "
    foreach ($typeitem in $projecttypesavailable)
    {
        write-output "- $typeitem"
    }
    write-output " "
    write-output "Inputs were:"
    write-output "- Tasks: $tasks"
    write-output "- ProjectType: $projecttype"
    write-output "- Environment: $environment"
    write-output "- DeployLocations: $deploylocations"
    write-output " "
    $exit1 = $true
    return $exit1
}



function Deploy-Project
{
    param(
        $targetlocations,
        $DeploymentUsername,
        $DeploymentPassword,
        $DeploymentSourceRoot,
        $projecttype
    )

    

    if (!$DeploymentUsername)
    {
        write-output "No deployment username specified. Quitting with exit code 1"
        exit 1
    }

    $cred = New-ObsCredentialObject -username $DeploymentUsername -password $DeploymentPassword
    $PSDriveName = "GitlabDeployTemp"
    

    $targetlocationcount = 0
    $numberoftargetlocations = ($targetlocations | measure-object).count
    foreach ($targetlocation in $targetlocations)
    {
        $targetlocationcount ++
        write-output " "
        write-output "Deployment location $targetlocationcount of $numberoftargetlocations"
        write-output "-----------------------------------------------"
        write-output "Starting deployment to $targetlocation"
        write-output " "
        #Create PS Drive
        New-PSDrive -Name $PSDriveName -PSProvider FileSystem -Root $targetlocation -Persist:$false -Credential $cred -Confirm:$false | out-null
        if ($?)
        {
            "Created psdrive $PSDriveName to $targetlocation"
        }
        
        #implemented for netcore deployments. purge items fails because files are in use.
        if (Test-Path $targetlocation\web.config) 
        { 
            Remove-Item -Path $targetlocation\web.config -Force -Confirm:$false 
            Write-Output "Removed web.config"
            #wait 10 seconds so that all open handles to files are closed
            Start-Sleep -Seconds 10
        }
        #clear out all items
        remove-item -Path "$targetlocation\*" -Recurse -Force -Confirm:$false -Include *
        if ($?)
        {
            "Cleared $targetlocation files"
        }


        #Copy files to Final location

            $exclusions = @('.git', '.vscode', '.gitlab-ci.yml')
            copy-item -Path "$DeploymentSourceRoot/*" -Recurse -Destination $targetlocation -Force -Exclude $exclusions -Confirm:$false
            if ($?)
            {
                "Copied files to $targetlocation"
            }

            remove-psdrive -Name $PSDriveName -Force -Confirm:$false
            if ($?)
            {
                "Removed psdrive $PSDriveName"
            }
        
        


    }



}

#region PowerShell Module functions
function Register-EAPSRepo
{
    param(
    [string]$Name,
    [string]$RepoURL
    )
    $repo = @{
    Name = $Name
    SourceLocation = $RepoURL
    PublishLocation = $RepoURL
    ScriptSourceLocation = $RepoURL.Substring(0,$RepoURL.Length-1)
    InstallationPolicy = 'Trusted'
    }
    Register-PSRepository @repo
}

function Config-EAPSRepo
{
    #Lots of code removed here, add your own repo config if you plan on using the powershell module deployments

    #Install NuGet Package Provider
    $NuGet = Get-PackageProvider -Name NuGet
    if (!$NuGet)
    {
        Install-PackageProvider -Name NuGet -ForceBootstrap -Force -Scope CurrentUser
    }

    #Clear non-terminating telementary error caused by get-psrepository
    if ($Error[0].categoryinfo.TargetName -eq 'Microsoft.PowerShell.Commands.PowerShellGet.Telemetry')
    {
        $Error.RemoveAt(0)
    }
}

function Deploy-PSModule
{
    param(
        [string]$Path,
        [string]$Environment
    )
    # Temporarily storing API key here until we decide what to do with them.
    if ($Environment -eq 'qa')
    {
    $Repository = 'removed'
    $NuGetAPIKey = 'removed'
    }
    elseif ($Environment -eq 'test')
    {
    $Repository = 'removed'
    $NuGetAPIKey = 'removed'
    }
    elseif ($Environment -eq 'prod')
    {
    $Repository = 'removed'
    $NuGetAPIKey = 'removed'
    }
    
    $currerr = $Error.count
    try
    {
        Publish-Module -Path $Path -Repository $Repository -NuGetApiKey $NuGetAPIKey -ErrorAction Ignore
        # I really didn't want to have to do this. Publish-Module always generates a non-terminating error because it tries to Find-Package
        # at the target version in the repo before publishing.
        # The catch block will still log an error if the module fails to publish.
        if ($currerr -lt $Error.count)
        {
	        $errdiff = $Error.Count - $currerr
	        for ($i = 0; $i -lt $errdiff; $i++)
	        {
		        $Error.RemoveAt(0)
	        }
        }

    }
    catch [System.InvalidOperationException]
    {
        Write-Output "Module at $Path is already listed in the Repository at the target version. Update the ModuleVersion attribute in the module manifest."
    }
    catch [System.IO.DirectoryNotFoundException]
    {
        Write-Output "Module or a dependency of module could not be found. Ensure that module depencencies exist in ENV:PSModulePath."
    }
} 

#endregion

#Start processing tasks
foreach ($task in $taskstodo)
{

    #region ------------POWERSHELL SECTION-------------
    if ($projecttype -eq "powershell")
    {
        write-output " "
        Write-Output "Starting $projecttype section"
        write-output " "

        if ($task -eq "analyze")
        {
            "Starting task: $task"
            "We don't have analyzing in place yet"
    
        }
        elseif ($task -eq "test")
        {
            "Starting task: $task"
            "We don't have any tests yet"
        }
        elseif ($task -eq "build")
        {
            "Starting task: $task"
            "No build needed for PowerShell projects"
        }
        elseif ($task -eq "deploy")
        {
            "Starting task: $task"
          
            $message = Get-GitCommitMessage
            write-output " "
            write-output "Git message: $message"
            write-output " "
    
            Write-Output "Deploying $projecttype Project to $environment environment"
            write-output " "
     
            Deploy-Project -targetlocations $targetlocations -DeploymentUsername $DeploymentUsername -DeploymentPassword $DeploymentPassword -DeploymentSourceRoot $deploymentsourceroot -projecttype $ProjectType
    
        }
        else 
        {
            $exit1 = invoke-notasksmatched -tasks $tasks -projecttype $ProjectType -environment $environment -deploylocations $deploylocations
            
        }
    }
    #endregion ------------POWERSHELL SECTION-------------
        
    #region ------------POWERSHELL MODULE SECTION-------------
    if ($projecttype -eq "powershellmodule")
    {
        write-output " "
        Write-Output "Starting $projecttype section"
        write-output " "

        if ($task -eq "analyze")
        {
            "Starting task: $task"
            
            Write-Output "Configuring Enterprise Automation Repositories"
            Config-EAPSRepo

            #Check if PSScriptAnalyzer is installed
            $PSScriptAnalyzer = Get-Module -Name PSScriptAnalyzer -ListAvailable
            if (!$PSScriptAnalyzer)
            {
                Write-Output "Installing PSScriptAnalyzer"
                Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.17.1 -Repository EA -Scope CurrentUser
            }

            $Modules = (Get-ChildItem -Directory).Name
            foreach ($Module in $Modules)
            {
                #Install module dependencies from prod repo
                $psd = Import-PowerShellDataFile .\$Module\$Module.psd1
                $RequiredModules = $psd.RequiredModules | ConvertTo-Json | ConvertFrom-Json
                if ($RequiredModules)
                {
                    Write-Output "Installing module dependencies"
                    foreach ($M in $RequiredModules)
                    {
                        Install-Module -Name $M.ModuleName -RequiredVersion $M.ModuleVersion -Repository EA -Scope CurrentUser
                    }
                }

                Write-Output "Invoking PSScriptAnalyzer"
                Invoke-ScriptAnalyzer -Path .\$Module
            }
    
        }
        elseif ($task -eq "test")
        {
            "Starting task: $task"
            
            #Check if Pester is installed
            $Pester = Get-Module -Name Pester -ListAvailable
            if (!$Pester)
            {
                Write-Output "Installing Pester"
                Install-Module -Name Pester -RequiredVersion 4.4.2 -Repository EA -Scope CurrentUser
            }

            $Modules = (Get-ChildItem -Directory).Name
            foreach ($Module in $Modules)
            {
                Write-Output "Invoking Pester"
                Invoke-Pester -Path .\$Module\Tests
            }
                #Clear non-terminating telementary error caused by PowerShellGet
            if ($Error[0].categoryinfo.TargetName -eq 'Microsoft.PowerShell.Commands.PowerShellGet.Telemetry')
            {
                $Error.RemoveAt(0)
            }
        }
        elseif ($task -eq "build")
        {
            "Starting task: $task"
            "No build needed for PowerShell projects"
        }
        elseif ($task -eq "deploy")
        {
            "Starting task: $task"
          
            $message = Get-GitCommitMessage
            write-output " "
            write-output "Git message: $message"
            write-output " "
    
            Write-Output "Deploying $projecttype Project to $environment environment"
            write-output " "

            #Deploy each module directory in the project
            $Modules = (Get-ChildItem -Directory).Name
            foreach ($Module in $Modules)
            {
                Deploy-PSModule -Path .\$Module -Environment $environment
            }
        }
        else 
        {
            $exit1 = invoke-notasksmatched -tasks $tasks -projecttype $ProjectType -environment $environment -deploylocations $deploylocations
            
        }
    }
    
    #endregion ------------POWERSHELL MODULE SECTION-------------



    #region ---------DOT NET CLASSIC SECTION---------
    elseif ($ProjectType -eq "netclassic")
    {
        write-output " "
        Write-Output "Starting $projecttype section"
        write-output " "

        if ($task -eq "analyze")
        {
            "Starting task: $task"
            "We don't have analyzing in place yet"

        }
        elseif ($task -eq "test")
        {
            "Starting task: $task"
            "We don't have any tests yet"
        }
        elseif ($task -eq "build")
        {
            "Starting task: $task"

            $netclassicsolutionfile = (get-childitem -Path "./" -Filter "*.sln")[0]
            write-output "Solution file: "
            $netclassicsolutionfile
            $netclassicsolutionfilename = $netclassicsolutionfile.name

            if ($netclassicsolutionfile.count -eq 0)
            {
                write-output "No solution files found. Exiting with exit code of 1"
                exit 1
            }
            $netclassicbasename = $netclassicsolutionfile.basename
            write-output "Starting build of $netclassicbasename"
       
            $buildoutput = invoke-msbuild -Path $netclassicsolutionfilename -keepbuildlogonsuccessfulbuilds -MsBuildParameters "/p:Configuration=$environment /p:PublishProfile=$environment /p:DeployOnBuild=true /p:DeleteExistingFiles=True /p:DeployDefaultTarget=WebPublish /p:WebPublishMethod=FileSystem /p:ExcludeApp_Data=false /p:publishUrl=$TempBuildLocation\$netclassicbasename"

            write-output "Command used to build: " 
            write-output $buildoutput.commandusedtobuild

            if ($buildoutput.buildsucceeded)
            {
                #currently won't write out log if successful - remove comments below to enable this
                #$log = get-content $buildoutput.BuildLogFilePath
                #write-output $log
                write-output " "
                write-output "Successfully built solution $netclassicbasename"
            }
            else
            {
                
                write-output "Error log output: "
                $log = get-content $buildoutput.BuildLogFilePath
                write-output $log
                write-output " "
                write-output "Failed to build solution $netclassicbasename"
                $exit1 = $true
            }



        }
        elseif ($task -eq "deploy")
        {
            "Starting task: $task"
      
            $message = Get-GitCommitMessage
            write-output " "
            write-output "Git message: $message"
            write-output " "

            Write-Output "Deploying $projecttype Project to $environment environment"
            write-output " "

            $netclassicsolutionfile = (get-childitem -Path "./" -Filter "*.sln")[0]
            $netclassicsolutionfilename = $netclassicsolutionfile.name
            $netclassicbasename = $netclassicsolutionfile.basename
            $deploymentroot = "$TempBuildLocation\$netclassicbasename"

 
            Deploy-Project -targetlocations $targetlocations -DeploymentUsername $DeploymentUsername -DeploymentSourceRoot $DeploymentRoot -projecttype $ProjectType

        }
        else
        {
            $exit1 = invoke-notasksmatched -tasks $tasks -projecttype $ProjectType -environment $environment -deploylocations $deploylocations
        }
    }
    #endregion --------DOT NET CLASSIC SECTION-------------


    #region ---------DOT NET CORE SECTION---------
    elseif ($ProjectType -eq "netcore")
    {
        write-output " "
        Write-Output "Starting $projecttype section"
        write-output " "
        if ($task -eq "analyze")
        {
            "Starting task: $task"
            "We don't have analyzing in place yet"

        }
        elseif ($task -eq "test")
        {
            "Starting task: $task"
            "We don't have any tests yet"
        }
        elseif ($task -eq "build")
        {
            "Starting task: $task"
            
            $netcoresolutionfile = (get-childitem -Path "./" -Filter "*.sln")[0]
            write-output "Solution file: "
            $netcoresolutionfile
            Write-Output ""
            $netcoresolutionfilename = $netcoresolutionfile.name

            if ($netcoresolutionfile.count -eq 0)
            {
                write-output "No solution files found. Exiting with exit code of 1"
                exit 1
            }
            $netcorebasename = $netcoresolutionfile.basename
            
            if (-not (Test-Path $TempBuildLocation\$netcorebasename))
            {
                write-output "Creating Temp Build Location for $netcorebasename"
                New-Item -Path $TempBuildLocation -Name $netcorebasename -ItemType Directory
            }
            else
            {
                write-output "Clearing Temp Build Location for $netcorebasename"
                remove-item -Path "$TempBuildLocation\$netcorebasename\*" -Recurse -Force -Confirm:$false -Include *
            }
            
            Write-Output ""
            write-output "Starting build of $netcorebasename"

            $buildconfig = "/p:Configuration=$environment"
            $buildprofile = "/p:PublishProfile=$environment" 
            $buildlocation = "-o:$TempBuildLocation\$netcorebasename"
            $buildlogfilepath = "C:\Users\$ENV:USERNAME\AppData\Local\Temp\$netcorebasename.sln.msbuild.log"
            $buildlog =  "/fileLoggerParameters:LogFile=`"$buildlogfilepath`""
            #dotnet publish builds and publishes to specified location using the ASPNETCORE_ENVIRONMENT variable defined in publish profile
            $buildoutput = dotnet publish $buildconfig $buildprofile $buildlocation $buildlog

            $buildsuccess = $?
            [bool] $buildOutputDoesNotContainFailureMessage = (Select-String -Path $buildLogFilePath -Pattern "Build FAILED." -SimpleMatch) -eq $null
            Write-Output ""
            if ($buildsuccess -and $buildOutputDoesNotContainFailureMessage)
            {
                Write-Output "Successfully built $netcorebasename"
            }
            else
            {
                Write-Output "Failed to build $netcorebasename"
                Write-Output ""
                Write-Output "Build Output:"
                Write-Output "$buildoutput"
                $exit1 = $true
            }
            Write-Output ""
            Write-Output "Command used to build: dotnet publish $buildconfig $buildprofile $buildlocation $buildlog"
            Write-Output ""
            Write-Output "Build log: C:\Users\$ENV:USERNAME\AppData\Local\Temp\$netcorebasename.sln.msbuild.log"
        }
        elseif ($task -eq "deploy")
        {
            "Starting task: $task"
      
            $message = Get-GitCommitMessage
            write-output " "
            write-output "Git message: $message"
            write-output " "

            Write-Output "Deploying $projecttype Project to $environment environment"
            write-output " "

            $netcoresolutionfile = (get-childitem -Path "./" -Filter "*.sln")[0]
            $netcoresolutionfilename = $netcoresolutionfile.name
            $netcorebasename = $netcoresolutionfile.basename
            $deploymentroot = "$TempBuildLocation\$netcorebasename"

 
            Deploy-Project -targetlocations $targetlocations -DeploymentUsername $DeploymentUsername -DeploymentSourceRoot $DeploymentRoot -projecttype $ProjectType

        }
        else
        {
            $exit1 = invoke-notasksmatched -tasks $tasks -projecttype $ProjectType -environment $environment -deploylocations $deploylocations
        }
    }
    #endregion --------DOT NET CORE SECTION-------------


    #region ------------HTML SECTION-------------
    elseif ($projecttype -eq "html")
    {
        write-output " "
        Write-Output "Starting $projecttype section"
        write-output " "

        if ($task -eq "analyze")
        {
            "Starting task: $task"
            "We don't have analyzing in place yet"
    
        }
        elseif ($task -eq "test")
        {
            "Starting task: $task"
            "We don't have any tests yet"
        }
        elseif ($task -eq "build")
        {
            "Starting task: $task"
            "No build needed for HTML projects"
        }
        elseif ($task -eq "deploy")
        {
            "Starting task: $task"
            
            $message = Get-GitCommitMessage
            write-output " "
            write-output "Git message: $message"
            write-output " "
    
            Write-Output "Deploying $projecttype Project to $environment environment"
            write-output " "
        
            Deploy-Project -targetlocations $targetlocations -DeploymentUsername $DeploymentUsername -DeploymentSourceRoot $deploymentsourceroot -projecttype $ProjectType
    
        }
        else 
        {
            $exit1 = invoke-notasksmatched -tasks $tasks -projecttype $ProjectType -environment $environment -deploylocations $deploylocations
            
        }
    }
    #endregion ------------HTML SECTION-------------


    #region ------------GENERIC FILE COPY SECTION-------------
    elseif ($projecttype -eq "genericcopy")
    {
        write-output " "
        Write-Output "Starting $projecttype section"
        write-output " "

        if ($task -eq "analyze")
        {
            "Starting task: $task"
            "We don't have analyzing in place yet"
    
        }
        elseif ($task -eq "test")
        {
            "Starting task: $task"
            "We don't have any tests yet"
        }
        elseif ($task -eq "build")
        {
            "Starting task: $task"
            "No build needed for generic file copy projects"
        }
        elseif ($task -eq "deploy")
        {
            "Starting task: $task"
            
            $message = Get-GitCommitMessage
            write-output " "
            write-output "Git message: $message"
            write-output " "
    
            Write-Output "Deploying $projecttype Project to $environment environment"
            write-output " "
        
            Deploy-Project -targetlocations $targetlocations -DeploymentUsername $DeploymentUsername -DeploymentSourceRoot $deploymentsourceroot -projecttype $ProjectType
    
        }
        else 
        {
            $exit1 = invoke-notasksmatched -tasks $tasks -projecttype $ProjectType -environment $environment -deploylocations $deploylocations
            
        }
    }
    #endregion ------------GENERIC FILE COPY SECTION-------------

    #region ---------DOT NET CORE ON KUBERNETES SECTION--------- BETA
    elseif ($ProjectType -eq "netcore-k8s")
    {
        write-output " "
        Write-Output "Starting $projecttype section"
        write-output " "
        if ($task -eq "analyze")
        {
            "Starting task: $task"
            "We don't have analyzing in place yet"

        }
        elseif ($task -eq "test")
        {
            "Starting task: $task"
            "We don't have any tests yet"
        }
        elseif ($task -eq "build")
        {
            "Starting task: $task"
            
            $netcoresolutionfile = (get-childitem -Path "./" -Filter "*.sln")[0]
            write-output "Solution file: "
            $netcoresolutionfile
            Write-Output ""
            $netcoresolutionfilename = $netcoresolutionfile.name

            if ($netcoresolutionfile.count -eq 0)
            {
                write-output "No solution files found. Exiting with exit code of 1"
                exit 1
            }
            $netcorebasename = $netcoresolutionfile.basename
            
            if (-not (Test-Path $TempBuildLocation\$netcorebasename))
            {
                write-output "Creating Temp Build Location for $netcorebasename"
                New-Item -Path $TempBuildLocation -Name $netcorebasename -ItemType Directory
            }
            else
            {
                write-output "Clearing Temp Build Location for $netcorebasename"
                remove-item -Path "$TempBuildLocation\$netcorebasename\*" -Recurse -Force -Confirm:$false -Include *
            }
            
            Write-Output ""
            write-output "Starting build of $netcorebasename"

            $buildconfig = "/p:Configuration=$environment"
            $buildprofile = "/p:PublishProfile=$environment" 
            $buildlocation = "-o:$TempBuildLocation\$netcorebasename"
            $buildlogfilepath = "C:\Users\$ENV:USERNAME\AppData\Local\Temp\$netcorebasename.sln.msbuild.log"
            $buildlog =  "/fileLoggerParameters:LogFile=`"$buildlogfilepath`""
            #dotnet publish builds and publishes to specified location using the ASPNETCORE_ENVIRONMENT variable defined in publish profile
            #this works for windows/IIS, but we need to configure container images differently
            $buildoutput = dotnet publish $buildconfig $buildprofile $buildlocation $buildlog

            $buildsuccess = $?
            [bool] $buildOutputDoesNotContainFailureMessage = $null -eq (Select-String -Path $buildLogFilePath -Pattern "Build FAILED." -SimpleMatch)
            Write-Output ""
            if ($buildsuccess -and $buildOutputDoesNotContainFailureMessage)
            {
                Copy-Item -Path ".\Dockerfile-$Environment" -Destination "$TempBuildLocation\$netcorebasename\Dockerfile"
                Write-Output "Successfully built $netcorebasename"
                Write-Output ""
                Write-Output "Copied Dockerfile for $Environment to build directory"
                
                if (Test-Path $ObservicingCertificatePfx)
                {
                    Copy-Item -Path $ObservicingCertificatePfx -Destination "$TempBuildLocation\$netcorebasename\cert.pfx"
                    Write-Output "Copied SSL Certificate"
                }

                if (Test-Path .\apisqlsvc.keytab)
                {
                    Copy-Item -Path ".\apisqlsvc.keytab" -Destination "$TempBuildLocation\$netcorebasename\apisqlsvc.keytab"
                    Write-Output "Copied keytab file for kerberos auth"
                }

                if (Test-Path .\cron-kinit-6hr)
                {
                    Copy-Item -Path ".\cron-kinit-6hr" -Destination "$TempBuildLocation\$netcorebasename\cron-kinit-6hr"
                    Write-Output "Copied cron job for kerberos ticker renewals"
                }

                if (Test-Path .\krb5.conf)
                {
                    Copy-Item -Path ".\krb5.conf" -Destination "$TempBuildLocation\$netcorebasename\krb5.conf"
                    Write-Output "Copied krb5.conf - kerberos configuration"
                }

                if (Test-Path .\launch.sh-$Environment)
                {
                    Copy-Item -Path ".\launch.sh-$Environment" -Destination "$TempBuildLocation\$netcorebasename\launch.sh"
                    Write-Output "Copied entrypoint launch.sh script"
                }
                
            }
            else
            {
                Write-Output "Failed to build $netcorebasename"
                Write-Output ""
                Write-Output "Build Output:"
                Write-Output "$buildoutput"
                $exit1 = $true
            }
            Write-Output ""
            Write-Output "Command used to build: dotnet publish $buildconfig $buildprofile $buildlocation $buildlog"
            Write-Output ""
            Write-Output "Build log: C:\Users\$ENV:USERNAME\AppData\Local\Temp\$netcorebasename.sln.msbuild.log"





        }
        elseif ($task -eq "deploy")
        {
            "Starting task: $task"
      
            $message = Get-GitCommitMessage
            write-output " "
            write-output "Git message: $message"
            write-output " "

            Write-Output "Deploying $projecttype Project to $environment environment"
            write-output " "
            #Write-Output "Container registry URL: $ContainerRegistryUrl"
            $netcoresolutionfile = (get-childitem -Path "./" -Filter "*.sln")[0]
            $netcoresolutionfilename = $netcoresolutionfile.name
            $netcorebasename = $netcoresolutionfile.basename
            $deploymentroot = "$TempBuildLocation\$netcorebasename"
            #write-output " "
            Write-Output "DeploymentRoot: $Deploymentroot"
            
            #kubernetes deployment should always equal netcorebasename - unless we use another variable

            #add logic to auto install module from local repo
            if ((Get-Module Posh-SSH -ListAvailable | Measure-Object).count -lt 1)
            {
                throw "Posh-SSH is required for this stage."
                exit 1
            }
            Import-Module Posh-SSH
            
            $imgguid = New-Guid
            $AppDir = "/mnt/obs-data/GitlabBuilds/$netcorebasename"
            Write-Output "Building from the following location on Unix: $AppDir"
            $BuildImageCmd = "cd $AppDir ; docker build -t $netcorebasename ."
            Write-Output "Docker Build Command: $BuildImageCmd"

            $DockerLoginCmd = "docker login registry.gitlab.com -u removed -p removed"
            Write-Output "Docker Login Command: $DockerLoginCmd"

            $TagImageCmd = "docker tag $($netcorebasename):latest $($ContainerRegistryUrl):$($imgguid)"
            Write-Output "Tag Command: $TagImageCmd"

            $PublishImageCmd = "docker push $($ContainerRegistryUrl):$($imgguid)"
            Write-Host "Push image to registry command: $PublishImageCmd"

            $DeployCmd = "kubectl set image deployment $netcorebasename $($netcorebasename)=$($ContainerRegistryUrl):$($imgguid)"
            Write-Output "Deploy to Kubernetes Command: $DeployCmd"
            Write-Output ""

            $SshCred = New-ObsCredentialObject -username $DockerUsername -password $DockerPassword
            
            $SshSession = New-SSHSession -ComputerName $DockerBuildServer -Credential $SshCred
            if ($SshSession.Connected -ne $true) {throw "failed to connect to $DockerBuildServer" ; exit 1}
            else {Write-Output "Successfully Connected to $DockerBuildServer"}
            
            $Build = Invoke-SSHCommand -Command $BuildImageCmd -SSHSession $SshSession -TimeOut 500
            if ($Build.ExitStatus -ne 0) {throw "failed to build docker image" ; exit 1}
            else {Write-Output "Successfully built new image"}
            
            $Login = Invoke-SSHCommand -Command $DockerLoginCmd -SSHSession $SshSession
            if ($Login.ExitStatus -ne 0) {throw "failed to execute docker login" ; exit 1}
            else {Write-Output "Successfully executed Docker login to registry.gitlab.com"}
            
            $Tag = Invoke-SSHCommand -Command $TagImageCmd -SSHSession $SshSession
            if ($Tag.ExitStatus -ne 0) {throw "failed tagging new image" ; exit 1}
            else {Write-Output "Successfully tagged new image"}
            
            $Publish = Invoke-SSHCommand -Command $PublishImageCmd -SSHSession $SshSession -TimeOut 100000
            if ($Publish.ExitStatus -ne 0) {throw "failed publishing to container registry" ; exit 1}
            else {Write-Output "Successfully pushed image to registry"}
            
            $Remove = Remove-SSHSession $SshSession
            Write-Output "Disconnected from $DockerBuildHost"
            Write-Output ""
            
            #re pull kube image
            $SshSession = New-SSHSession -ComputerName $KubernetesCluster -Credential $SshCred -AcceptKey -Force
            if ($SshSession.Connected -ne $true) {$SshSession ; throw "failed to connect" ; exit 1}
            else {Write-Output "Successfully Connected to $KubernetesCluster"}
            
            $Deploy = Invoke-SSHCommand -Command $DeployCmd -SSHSession $SshSession
            if ($Deploy.ExitStatus -ne 0) {$Deploy.output; $Error ; throw "failed" ; exit 1}
            else {Write-Output "Successfully pulled image from repository to Kubernetes"}
            
            
            $Remove = Remove-SSHSession $SshSession
            Write-Output "Disconnected from $KubernetesCluster"
            Write-Output ""


        }
        else
        {
            $exit1 = invoke-notasksmatched -tasks $tasks -projecttype $ProjectType -environment $environment -deploylocations $deploylocations
        }
    }
    #endregion --------DOT NET CORE ON KUBERNETES SECTION-------------

    else
    {
      
            invoke-notprojecttypesmatched -tasks $tasks -projecttype $projecttype -environment $environment -deploylocations $deploylocations
   
    }




  
}









write-output "End of deploy script build.ps1"

#Check error count
$errorcount = $error.Count
if ($errorcount -gt 0 -or $exit1 -eq $true)
{
    "Errors encountered"
    $Error
    exit 1
}
else
{
    exit 0
}