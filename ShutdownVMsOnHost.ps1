#
# Shuts down as gracefully as possible all VMs on a given set of hosts
#
 
#
# Script parameters
#
param
(
   [string] $action,
   [string] $serverFile,
   [string] $vCenter,
   [string] $DDC
)
 
 
#
# Sample usage:
#
# .\ShutdownVMsOnHost.ps1 shutdown servers.txt vCenterServer XenDesktopDDC_FQDN
#
 
 
#
# General options
#
#Requires -Version 2
Set-StrictMode -Version 2
 
 
#
# Global variables
#
 
$scriptDir = Split-Path $MyInvocation.MyCommand.Path
$logfile = $scriptDir + "\log.txt"
$runningVMs = $scriptDir + "\vms.txt"
$vmsPoweringDown = new-object system.collections.arraylist
$vmNameFilter = "*"                                         # Optionally filter the VMs to process
 
 
#
# Constants
#
# Return values
Set-Variable -Name RET_OK -Value 0 -Option ReadOnly -Force      # Successful execution
Set-Variable -Name RET_HELP -Value 1 -Option ReadOnly -Force    # The help page was printed
Set-Variable -Name RET_ERROR -Value 2 -Option ReadOnly -Force   # An error occured
 
# Log message severity
Set-Variable -Name SEV_INFO -Value 1 -Option ReadOnly -Force
Set-Variable -Name SEV_WARN -Value 2 -Option ReadOnly -Force
Set-Variable -Name SEV_ERR -Value 3 -Option ReadOnly -Force
 
 
#
# This is the real start of the script
#
function main
{
   try
   {
      if (-not (Test-Path $serverFile))
      {
         throw "File not found: $serverFile"
      }
 
      # Load snapins and modules
      LogMessage "Loading PowerShell snapins and connecting to vCenter (may take a while)..." $SEV_INFO
      LoadSnapins @("VMware.VimAutomation.Core")
      LoadSnapins @("Citrix.ADIdentity.Admin.V1")
      LoadSnapins @("Citrix.Broker.Admin.V1")
      LoadSnapins @("Citrix.Common.Commands")
      LoadSnapins @("Citrix.Configuration.Admin.V1")
      LoadSnapins @("Citrix.Host.Admin.V1")
      LoadSnapins @("Citrix.MachineCreation.Admin.V1")
      LoadSnapins @("Citrix.MachineIdentity.Admin.V1")
 
      # Connect to vCenter
      try
      {
         Disconnect-VIServer $vCenter -confirm:$false -ErrorAction SilentlyContinue
      }
      catch
      {
        # Do nothing
      }
      $script:viserver = Connect-VIServer $vCenter -NotDefault
 
      # Do it
      if ($action -eq "shutdown")
      {
         ShutdownVMs
      }
      elseif ($action -eq "startup")
      {
         StartupVMs
      }
      else
      {
         throw New-Object System.ArgumentNullException "Unknown action: $action"
      }
   }
   catch
   {
      LogMessage ("Error: " + $_.Exception.Message.ToString()) $SEV_ERR
      exit $RET_ERROR
   }
}
 
##############################################
#
# Shutdown VMs
#
##############################################
 
function ShutdownVMs ()
{
   LogMessage "========================================="
   LogMessage "`nInitiating shutdown...`n"
 
   # Delete the VM file
   if (Test-Path $runningVMs)
   {
      Remove-Item $runningVMs
   }
 
   # Process each server in the list
   get-content $serverFile | foreach {
 
      if ([string]::IsNullOrEmpty($_))
      {
         return;  # Next line
      }
 
      LogMessage "Server $_..."
 
      # Get all VMs on this server
      $vms = Get-VM -Location $_ -name $vmNameFilter -Server $viserver -ErrorAction stop
 
      # Process each VM on this server
      foreach ($vm in $vms)
      {
         LogMessage "   VM $($vm.Name)..."
 
         # Enable XenDesktop maintenance mode
         try
         {
            Get-BrokerPrivateDesktop -MachineName "*\$($vm.Name)" -AdminAddress $DDC | Set-BrokerPrivateDesktop -InMaintenanceMode $true
         }
         catch
         {
            LogMessage ("Error while trying to enable maintenance mode: " + $_.Exception.Message.ToString()) $SEV_ERR
 
            # Next item in the foreach loop
            return
         }
 
         # Further process only VMs that are powered on
         if ($vm.PowerState -eq "PoweredOn")
         {
            # Store the running VMs
            Add-Content -path $runningVMs $vm.Name
 
            # Try a clean shutdown, if not possible turn off
            $vmView = $vm | get-view
            $vmToolsStatus = $vmView.summary.guest.toolsRunningStatus
            if ($vmToolsStatus -eq "guestToolsRunning")
            {
               $result = Shutdown-VMGuest -VM $vm -confirm:$false
               $count = $vmsPoweringDown.add($vm)
            }
            else
            {
               stop-vm -vm $vm -confirm:$false -Server $viserver
            }
         }
      }
   }
 
   # Wait until all VMs are powered down (or we reach a timeout)
   $waitmax = 3600
   $startTime = (get-date).TimeofDay
   do
   {
      LogMessage "`nWaiting 1 Minute...`n"
      sleep 60
 
      LogMessage "Checking for still running machines...`n"
 
      for ($i = 0; $i -lt $vmsPoweringDown.count; $i++)
      {
         if ((Get-VM $vmsPoweringDown[$i] -Server $viserver).PowerState -eq "PoweredOn")
         {
            continue
         }
         else
         {
            $vmsPoweringDown.RemoveAt($i)
            $i--
         }
      }
   } while (($vmsPoweringDown.count -gt 0) -and (((get-date).TimeofDay - $startTime).seconds -lt $waitmax))
 
   # Shut down still running VMs
   if ($vmsPoweringDown.count -gt 0)
   {
      LogMessage "Powering down still running machines...`n"
 
      foreach ($vmName in $vmsPoweringDown)
      {
         $vm = Get-VM $vmName -Server $viserver
         if ($vm.PowerState -eq "PoweredOn") {
            Stop-VM -vm $vm -confirm:$false -Server $viserver
         }
      }
   }
 
   LogMessage "`nDone!`n"
}
 
##############################################
#
# Startup VMs
#
##############################################
 
function StartupVMs ()
{
   LogMessage "========================================="
   LogMessage "`nInitiating startup...`n"
 
   # Startup VMs that were previously running
   get-content $runningVMs | foreach {
 
      if ([string]::IsNullOrEmpty($_))
      {
         return;  # Next line
      }
 
      # Get the VM
      $vm = Get-VM -name $_ -Server $viserver
 
      # Start the VM
      Start-VM -vm $vm -confirm:$false -Server $viserver
   }
 
   # Disable XenDesktop maintenance mode for all VMs
   get-content $serverFile | foreach {
 
      # Get all VMs on this server
      $vms = Get-VM -Location $_ -name $vmNameFilter -Server $viserver
 
      # Process each VM on this server
      foreach ($vm in $vms)
      {
         # Disable XenDesktop maintenance mode
         try
         {
            Get-BrokerPrivateDesktop -MachineName "*\$($vm.Name)" -AdminAddress $DDC | Set-BrokerPrivateDesktop -InMaintenanceMode $false
         }
         catch
         {
            LogMessage ("Error while disabling maintenance mode: " + $_.Exception.Message.ToString()) $SEV_ERR
 
            # Next item in the foreach loop
            return
         }
      }
   }
 
   LogMessage "`nFertig!`n"
}
 
##############################################
#
# LogMessage
#
##############################################
 
function LogMessage ([String[]] $messages)
{
 
   $timestamp = $([DateTime]::Now).ToString()
 
   foreach ($message in $messages)
   {
      if ([string]::IsNullOrEmpty($message))
      {
         continue
      }
 
      Write-Host "$message"
 
      $message = $message.Replace("`r`n", " ")
      $message = $message.Replace("`n", " ")
      Add-Content $logFile "$timestamp $message"
   }
}
 
##############################################
#
# LoadSnapins
#
# Load one or more PowerShell-Snapins
#
##############################################
 
function LoadSnapins([string[]] $snapins)
{
   $loaded = Get-PSSnapin -Name $snapins -ErrorAction SilentlyContinue | % {$_.Name}
   $registered = Get-pssnapin -Name $snapins -Registered -ErrorAction SilentlyContinue  | % {$_.Name}
   $notLoaded = $registered | ? {$loaded -notcontains $_}
 
   if ($notLoaded -ne $null)
   {
      foreach ($newlyLoaded in $notLoaded)
	  {
         Add-PSSnapin $newlyLoaded
      }
   }
}
 
 
##############################################
#
# Start the script by calling main
#
##############################################
 
main
