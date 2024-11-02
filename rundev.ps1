using namespace System.IO
using namespace System.Threading
using namespace System.Diagnostics
using namespace System.Threading.Tasks
using namespace System.Management.Automation
using namespace System.Runtime.InteropServices

# .SYNOPSIS
#   start the extension in developer mode
# .DESCRIPTION
#   Builds and programmatically loads the extension in developer mode
# .NOTES
#   only tested on chrome.
# .LINK
#   https://github.com/alainQtec/get-gpt-voice/blob/main/rundev.ps1
# .EXAMPLE
#   ./rundev.ps1 -Verbose
#   assumes the buildoutput is in the same directory as the script
# [CmdletBinding()]
param (
  [Parameter(Position = 0, Mandatory = $false, ValueFromPipeline = $true)]
  [validatescript({ Test-Path $_ -PathType Container })]
  [string]$ProjectPath = $PSScriptRoot
)
begin {
  class BuildHelper {
    [string] $RootPath
    [string] $Manifest
    [string] $BuildOutput
    [string] $PackageJson
    static hidden [pscustomobject] $PkgJsonContent
    BuildHelper([string]$RootPath) {
      $this.RootPath = [BuildHelper]::GetResolvedPath($RootPath)
      $this.Manifest = [Path]::Combine($RootPath, "src", "manifest.json")
      $this.BuildOutput = [Path]::Combine($RootPath, "build")
      $this.PackageJson = [Path]::Combine($RootPath, "package.json")
      [BuildHelper]::PkgJsonContent = Get-Content $this.PackageJson -Raw | ConvertFrom-Json
    }
    static [string] GetResolvedPath([string]$Path) {
      return [BuildHelper]::GetResolvedPath($((Get-Variable ExecutionContext).Value.SessionState), $Path)
    }
    static [string] GetResolvedPath([System.Management.Automation.SessionState]$session, [string]$Path) {
      $paths = $session.Path.GetResolvedPSPathFromPSPath($Path);
      if ($paths.Count -gt 1) {
        throw [IOException]::new([string]::Format([cultureinfo]::InvariantCulture, "Path {0} is ambiguous", $Path))
      } elseif ($paths.Count -lt 1) {
        throw [IOException]::new([string]::Format([cultureinfo]::InvariantCulture, "Path {0} not Found", $Path))
      }
      return $paths[0].Path
    }
    static [string] GetHostOs() {
      return $(switch ($true) {
          $([RuntimeInformation]::IsOSPlatform([OSPlatform]::Windows)) { "Windows"; break }
          $([RuntimeInformation]::IsOSPlatform([OSPlatform]::FreeBSD)) { "FreeBSD"; break }
          $([RuntimeInformation]::IsOSPlatform([OSPlatform]::Linux)) { "Linux"; break }
          $([RuntimeInformation]::IsOSPlatform([OSPlatform]::OSX)) { "MacOSX"; break }
          Default {
            "UNKNOWN"
          }
        }
      )
    }
    static [string] GetAuthorName() {
      $AuthorName = [Environment]::GetEnvironmentVariable('UserName')
      try {
        $OS = [BuildHelper]::GetHostOs()
        $AuthorName = switch ($true) {
          $($OS -eq "Windows") {
            Get-CimInstance -ClassName Win32_UserAccount -Verbose:$false | Where-Object { [Environment]::UserName -eq $_.Name } | Select-Object -ExpandProperty FullName
            break
          }
          $($OS -in ("MacOSX", "Linux")) {
            $s = getent passwd "$([Environment]::UserName)"
            $s.Split(":")[4]
            break
          }
          Default {
            Write-Warning -Message "$([Environment]::OSVersion.Platform) OS is Not supported!"
          }
        }
      } catch {
        throw $_
      }
      return $AuthorName
    }
    static [string] GetAuthorEmail() {
      if ($null -ne (Get-Command git -CommandType Application)) {
        return git config --get user.email
      }
      Write-Warning "Can't find your email address."
      return "$([Environment]::UserName)@gmail.com" # nope,straight BS!
    }
    [Process] StartProcess([string]$FileName, [string[]]$Arguments) {
      $p = [Process]::new()
      $p.StartInfo.FileName = $FileName
      $p.StartInfo.Arguments = $Arguments
      $p.StartInfo.WorkingDirectory = $this.RootPath
      $p.StartInfo.UseShellExecute = $false
      $p.StartInfo.RedirectStandardInput = $true
      $p.StartInfo.CreateNoWindow = $false
      [void]$p.Start(); return $p
    }
    # Function to detect the default terminal, including Hyprland support
    static [tuple[string, Process]] GetCurrentTerminal() {
      # Define a list of known terminal emulators
      $names = @("alacritty", "kitty", "xfce4-terminal", "gnome-terminal", "konsole", "foot", "wezterm", "xterm", "mate-terminal")
      # Traverse up the process tree to find it
      $r = $null; $p = (Get-Process -Id $(Get-Variable PID).Value); $n = [string]::Empty;
      do {
        if ($names.Contains($p.ProcessName)) {
          [string]$n = $p.Path; $r = [tuple[string, Process]]::new($n, $p); $p = $null
        }; $p = $p.Parent
      } until ($null -eq $p -or ![string]::IsNullOrWhiteSpace($n))

      if ([string]::IsNullOrWhiteSpace($n)) {
        $(Get-Variable Host).Value.UI.WriteErrorLine("[BUG] Can't detect your terminal; supported terminals are: $($names -join ', ')")
      }
      return $r
    }
    [void] Build() {
      ![string]::IsNullOrWhiteSpace([BuildHelper]::PkgJsonContent.scripts.build) ? (npm run build | Out-Host) : (throw "Please set build script first")
    }
    [void] Publish() {
      ![string]::IsNullOrWhiteSpace([BuildHelper]::PkgJsonContent.scripts.publish) ? (npm run publish | Out-Host) : (throw "Please set publish script first")
    }
    [bool] Dev() {
      $_success = $false
      if (![string]::IsNullOrWhiteSpace([BuildHelper]::PkgJsonContent.scripts.dev)) {
        $r = [BuildHelper]::GetCurrentTerminal(); $c = [string]$r.Item2.CommandLine;
        $p = $null; $c += " --command npm run dev"
        Write-Host "[Run  dev] Launching $($r.Item1) ..." -f Green;
        try {
          [Process]$p = $this.StartProcess($r.Item1, $c.Substring($c.IndexOf(" ")).TrimStart())
          $_success = $?
        } catch {
          $_success = $false
        }
      } else {
        Write-Warning "Please set dev script first"
      }
      return $_success
    }
    [bool] LoadExtension() {
      if (![Path]::Exists($this.BuildOutput)) { $this.Build() }
      $ChromePath = $this.GetChromePath()
      if ($ChromePath) { Write-Host "[Load crx] Google Chrome found @ $ChromePath" -f Green }
      Write-Host "[Load crx] buildoutput: $($this.BuildOutput)" -f Green
      $arg = @("--load-extension=$($this.BuildOutput)")
      Start-Job -Name "chrome-dev-loadext" -ScriptBlock { &$args[0] $args[1] } -ArgumentList $ChromePath, $arg
      return $?
    }
    [bool] Invoke() {
      if ($this.IsPortListening(5173)) {
        return $this.LoadExtension()
      }
      $r = $this.Dev();
      Start-Sleep -Seconds 3 # wait vite dev server to fully start
      $r = $r -and ($this.LoadExtension())
      return $r
    }
    [string] GetChromePath() {
      # Check in each directory in $env:PATH
      $foundChromePath = [string]::Empty
      $IsInstalled = $false;
      $installpath = $env:PATH.Split([IO.Path]::PathSeparator).Where({ Test-Path "$_/google-chrome*" -PathType Leaf })
      if ($installpath) { $foundChromePath = (Get-ChildItem $installpath -Filter google-chrome*)[0]; $IsInstalled = $true; }
      # If Chrome wasn't found in $env:PATH, check known paths
      if ([string]::IsNullOrWhiteSpace($foundChromePath)) {
          ($foundChromePath, $IsInstalled) = switch ([buildhelper]::GetHostOs()) {
          "Windows" {
            $(Get-Item (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe').'(Default)').VersionInfo,
            $?
            break
          }
          "Linux" {
            # known paths to search for Google Chrome or Chromium
            $PathsToSsearch = [string[]]@(
              "/usr/bin/chromium",
              "/usr/bin/google-chrome",
              "/opt/google/chrome/chrome",
              "/usr/bin/chromium-browser",
              "/usr/bin/google-chrome-beta",
              "/usr/bin/google-chrome-stable",
              "/opt/google/chrome-beta/chrome",
              "/usr/bin/google-chrome-unstable",
              "/opt/google/chrome-unstable/chrome"
            )
            $chromebin = $null; $search_res = $PathsToSsearch.Where({ Test-Path $_ -PathType Leaf -ea Ignore });
            if ($search_res.Count -gt 0) {
              $chromebin = $search_res[0]
              if ($chromebin) {
                $msg = "found {0}" -f (&$chromebin --version | grep -iE "[0-9.]{10,20}")
                Write-Host $msg -f Green -NoNewline;
                Write-Host " @ $chromebin"
              }
            }
            $chromebin,
            ![string]::IsNullOrWhiteSpace($chromebin)
            break
          }
          Default {
            Get-Command chrome -ea SilentlyContinue,
            $?
          }
        }
      }
      if (!$IsInstalled) {
        $PSCmdlet.ThrowTerminatingError(
          [ErrorRecord]::new("Google Chrome is not installed. Please install chrome first.",
            "GoogleChromeNotFound",
            [ErrorCategory]::ObjectNotFound,
            "Google Chrome"
          )
        )
      }
      return $foundChromePath
    }
    [bool] IsPortListening([int]$Port) {
      $_HostOs = [BuildHelper]::GetHostOs()
      $_Status = switch ($_HostOs) {
        "Linux" {
          # Use netstat or lsof to check for the port on Linux
          $result = &lsof -iTCP:$Port -sTCP:LISTEN -n -P 2>$null
          if ($result) {
            $l = $result.Split("`n")[1].Split(" ").Where({ ![string]::IsNullOrEmpty($_) }); $p = $l[8].Split(":")[-1]; $msg = "{0} PID:{1} is listening on port {2}" -f $l[0], $l[1], $p
            Write-Host $msg -f Green; $result = ![string]::IsNullOrWhiteSpace($p)
          }
          [bool]$result;
          break
        }
        "Windows" {
          (Test-NetConnection -ComputerName 'localhost' -Port $Port -InformationLevel Quiet);
          break
        }
        Default {
          Write-Warning "Port checking not implemented for OS: $_HostOS"
          $false
        }
      }
      return $_Status
    }
  }
}
process {
  $rc = @{
    1 = ("Successfuly", "Green")
    0 = ("With Errors", "Red")
  }
  $re = [BuildHelper]::New($ProjectPath).Invoke()
  $re = $rc[[int]$re]
}
end {
  Write-Host "rundev.ps1 completed $($re[0])" -f $re[1]
}