# ED Discovery Quantifier

ED Discovery Quantifier is a simple Journal application built to be used through a commandline tool such as cmd.exe or powershell in Windows.  The tool summarizes past exploration discoveries in a human-readable way.

## Usage

Run the application from a commandline tool such as cmd.exe or powershell.
* ./EDDiscoveryQuantifier -d=5 -e -w

### Flags

* -d: Specify the days from the current time you are running the application that you want the app to summarize.  -d=5 would summarize using logs from the past 5 days.
* -e: List the body names of any Earthlike worlds you have scanned.
* -w: List the body names of any Water worlds you have scanned.
