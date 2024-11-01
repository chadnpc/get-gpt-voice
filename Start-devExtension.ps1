function Start-devExtension {
  # .SYNOPSIS
  #   start the extension in developer mode
  # .DESCRIPTION
  #   Builds and programmatically loads the extension in developer mode
  # .NOTES
  #   only tested on chrome.
  # .LINK
  #   Specify a URI to a help page, this will show when Get-Help -Online is used.
  # .EXAMPLE
  #   Start-devExtension -Verbose
  #   assumes the buildoutput is in the same directory as the script
  [CmdletBinding()]
  param (
  )
  begin {
    $BinPath, $IsInstalled = switch ($true) {
      $IsWindows {
        $(Get-Item (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe').'(Default)').VersionInfo,
        $?
        break
      }
      $IsLinux {
        $paths_to_search = @(
          "/usr/bin/chromium",
          "/usr/bin/google-chrome",
          "/usr/bin/chromium-browser",
          "/usr/bin/google-chrome-stable",
          "/usr/bin/google-chrome-beta",
          "/usr/bin/google-chrome-unstable",
          "/opt/google/chrome/chrome",
          "/opt/google/chrome-beta/chrome",
          "/opt/google/chrome-unstable/chrome"
        )
        $search_res = $paths_to_search.Where({ Test-Path $_ -PathType Leaf -ErrorAction Ignore })
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
        Get-Command chrome -ErrorAction SilentlyContinue,
        $?
      }
    }
    if (!$IsInstalled) {
      Write-Error "chrome is not installed. Please install chrome first."
      return
    }
  }

  process {
    &chmod +x $myInvocation.PSCommandPath
    $buildoutput = [IO.Path]::Combine($PSScriptRoot, "build")
    Write-Host "Load crx from buildoutput: $buildoutput" -f Green
    &$BinPath --load-extension="$buildoutput"
  }

  end {

  }
};
Start-devExtension