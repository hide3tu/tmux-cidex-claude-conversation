# claude-ctl.ps1 - Windows ConPTY-based Claude CLI controller
# tmux send-keys equivalent using ConPTY + Named Pipe IPC
#
# Usage:
#   pwsh -File scripts/claude-ctl.ps1 start              # Launch Claude in ConPTY
#   pwsh -File scripts/claude-ctl.ps1 send "text"         # Send text + Enter
#   pwsh -File scripts/claude-ctl.ps1 enter               # Send Enter only
#   pwsh -File scripts/claude-ctl.ps1 wait [-Timeout 3600] # Wait for .claude_done
#   pwsh -File scripts/claude-ctl.ps1 kill                # Kill Claude process
#   pwsh -File scripts/claude-ctl.ps1 status              # Check if running
#   pwsh -File scripts/claude-ctl.ps1 log                 # Show ConPTY output log

param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "send", "enter", "wait", "kill", "status", "log", "server")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Text,

    [int]$Timeout = 3600
)

$ErrorActionPreference = "Stop"

# --- Resolve pwsh path ---
function Find-Pwsh {
    # 1. Environment variable override
    if ($env:PWSH_PATH -and (Test-Path $env:PWSH_PATH)) { return $env:PWSH_PATH }
    # 2. PATH
    $inPath = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    # 3. Known install locations
    $candidates = @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "$env:ProgramFiles(x86)\PowerShell\7\pwsh.exe",
        "$env:LOCALAPPDATA\Microsoft\PowerShell\pwsh.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    # 4. Give up
    throw "pwsh (PowerShell 7+) not found. Install it or set PWSH_PATH environment variable."
}
$script:PwshPath = Find-Pwsh

# --- Paths ---
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:PidFile = Join-Path $script:ProjectRoot "logs\.claude_pid"
$script:ServerPidFile = Join-Path $script:ProjectRoot "logs\.claude_server_pid"
$script:DoneFile = Join-Path $script:ProjectRoot "logs\.claude_done"
$script:PipeName = "claude-ctl"
$script:LogFile = Join-Path $script:ProjectRoot "logs\conpty.log"

# ============================================================
# ConPTY C# Helper (inline compiled)
# ============================================================

$conPtySource = @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class ConPtyHelper
{
    // --- Win32 Structures ---

    [StructLayout(LayoutKind.Sequential)]
    public struct COORD
    {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize;
        public int dwXCountChars, dwYCountChars, dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    // --- Win32 Constants ---
    private const uint PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;

    // --- Win32 Imports ---

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int ClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe, IntPtr lpPipeAttributes, int nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(string lpApplicationName, string lpCommandLine, ref SECURITY_ATTRIBUTES lpProcessAttributes, ref SECURITY_ATTRIBUTES lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    // --- State ---
    private static IntPtr _hPC = IntPtr.Zero;
    private static SafeFileHandle _inputWriteSide;
    private static SafeFileHandle _outputReadSide;
    private static StreamWriter _inputWriter;
    private static PROCESS_INFORMATION _procInfo;
    private static Thread _drainThread;
    private static volatile bool _outputAlive;
    private static StringBuilder _outputBuffer;

    /// <summary>
    /// Start a process inside a ConPTY pseudo-console.
    /// Returns the child process PID.
    /// </summary>
    public static int Start(string commandLine, string workingDir, int cols = 120, int rows = 40)
    {
        SafeFileHandle inputReadSide, outputWriteSide;

        if (!CreatePipe(out inputReadSide, out _inputWriteSide, IntPtr.Zero, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe (input) failed");
        if (!CreatePipe(out _outputReadSide, out outputWriteSide, IntPtr.Zero, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe (output) failed");

        var size = new COORD { X = (short)cols, Y = (short)rows };
        int hr = CreatePseudoConsole(size, inputReadSide, outputWriteSide, 0, out _hPC);
        if (hr != 0)
            throw new Win32Exception(hr, "CreatePseudoConsole failed");

        // Prepare attribute list
        var lpSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref lpSize);
        var si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
        si.lpAttributeList = Marshal.AllocHGlobal(lpSize);

        if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, ref lpSize))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, (IntPtr)PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, _hPC, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());

        var pSec = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>() };
        var tSec = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>() };

        // Build environment block without CLAUDECODE to avoid nested session detection
        var envVars = Environment.GetEnvironmentVariables();
        var envBuilder = new StringBuilder();
        foreach (System.Collections.DictionaryEntry entry in envVars)
        {
            string key = entry.Key.ToString();
            if (key.Equals("CLAUDECODE", StringComparison.OrdinalIgnoreCase)) continue;
            envBuilder.Append(key).Append('=').Append(entry.Value?.ToString()).Append('\0');
        }
        envBuilder.Append('\0'); // Double null terminator
        IntPtr envBlock = Marshal.StringToHGlobalUni(envBuilder.ToString());

        uint flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT;
        if (!CreateProcessW(null, commandLine, ref pSec, ref tSec, false, flags, envBlock, workingDir, ref si, out _procInfo))
        {
            Marshal.FreeHGlobal(envBlock);
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess failed");
        }
        Marshal.FreeHGlobal(envBlock);

        // Close ConPTY-owned pipe ends
        inputReadSide.Dispose();
        outputWriteSide.Dispose();

        // Set up input writer
        _inputWriter = new StreamWriter(new FileStream(_inputWriteSide, FileAccess.Write), new UTF8Encoding(false)) { AutoFlush = true };

        // Drain output pipe on background thread, buffer recent output for inspection
        _outputAlive = true;
        _outputBuffer = new StringBuilder();
        _drainThread = new Thread(() => {
            try {
                var buf = new byte[4096];
                var stream = new FileStream(_outputReadSide, FileAccess.Read);
                string logPath = Environment.GetEnvironmentVariable("CONPTY_LOG");
                StreamWriter log = null;
                if (!string.IsNullOrEmpty(logPath))
                    log = new StreamWriter(logPath, true, new UTF8Encoding(false)) { AutoFlush = true };
                int n;
                while ((n = stream.Read(buf, 0, buf.Length)) > 0) {
                    var text = Encoding.UTF8.GetString(buf, 0, n);
                    if (log != null) log.Write(text);
                    lock (_outputBuffer) {
                        _outputBuffer.Append(text);
                        // Keep only last 8KB to avoid unbounded growth
                        if (_outputBuffer.Length > 8192)
                            _outputBuffer.Remove(0, _outputBuffer.Length - 8192);
                    }
                }
                if (log != null) log.Dispose();
            } catch (Exception) { }
            _outputAlive = false;
        }) { IsBackground = true };
        _drainThread.Start();

        // Cleanup attribute list
        DeleteProcThreadAttributeList(si.lpAttributeList);
        Marshal.FreeHGlobal(si.lpAttributeList);

        return _procInfo.dwProcessId;
    }

    /// <summary>Send raw text to the ConPTY input pipe.</summary>
    public static void SendInput(string text)
    {
        if (_inputWriter == null) throw new InvalidOperationException("Not started");
        _inputWriter.Write(text);
        _inputWriter.Flush();
    }

    /// <summary>Send text, wait briefly, then send Enter as a separate write.</summary>
    public static void SendLine(string text)
    {
        SendInput(text);
        Thread.Sleep(100);
        SendEnter();
    }

    /// <summary>Send Enter only (CR byte, same as physical Enter key in ConPTY).</summary>
    public static void SendEnter()
    {
        SendInput("\r");
    }

    /// <summary>Check if the output buffer contains a given substring.</summary>
    public static bool OutputContains(string text)
    {
        if (_outputBuffer == null) return false;
        lock (_outputBuffer) { return _outputBuffer.ToString().Contains(text); }
    }

    /// <summary>Clear the output buffer.</summary>
    public static void ClearOutput()
    {
        if (_outputBuffer == null) return;
        lock (_outputBuffer) { _outputBuffer.Clear(); }
    }

    /// <summary>Return the current output buffer content (last 8KB).</summary>
    public static string GetOutput()
    {
        if (_outputBuffer == null) return "";
        lock (_outputBuffer) { return _outputBuffer.ToString(); }
    }

    /// <summary>Check if ConPTY session is still alive (output pipe open or process running).</summary>
    public static bool IsRunning()
    {
        // ConPTY output pipe alive means the pseudo-console is still active,
        // even if the initial child process exited (e.g. node wrapper -> real process)
        if (_outputAlive) return true;
        if (_procInfo.hProcess == IntPtr.Zero) return false;
        return WaitForSingleObject(_procInfo.hProcess, 0) == 0x00000102; // WAIT_TIMEOUT
    }

    /// <summary>Terminate the child process.</summary>
    public static void Kill()
    {
        if (_procInfo.hProcess != IntPtr.Zero)
        {
            TerminateProcess(_procInfo.hProcess, 1);
        }
    }

    /// <summary>Close everything and clean up.</summary>
    public static void Close()
    {
        try { _inputWriter?.Dispose(); } catch { }
        if (_hPC != IntPtr.Zero) { ClosePseudoConsole(_hPC); _hPC = IntPtr.Zero; }
        try { _outputReadSide?.Dispose(); } catch { }
        try { _inputWriteSide?.Dispose(); } catch { }
        if (_procInfo.hProcess != IntPtr.Zero) { CloseHandle(_procInfo.hProcess); _procInfo.hProcess = IntPtr.Zero; }
        if (_procInfo.hThread != IntPtr.Zero) { CloseHandle(_procInfo.hThread); _procInfo.hThread = IntPtr.Zero; }
    }
}
"@

# Compile only when needed (server mode)
function Ensure-ConPtyLoaded {
    if (-not ([System.Management.Automation.PSTypeName]'ConPtyHelper').Type) {
        Add-Type -TypeDefinition $conPtySource
    }
}

# ============================================================
# Named Pipe IPC
# ============================================================

function Send-PipeCommand {
    param([string]$Message)
    $client = $null
    try {
        $client = New-Object System.IO.Pipes.NamedPipeClientStream(".", $script:PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $client.Connect(5000)  # 5s timeout
        $writer = New-Object System.IO.StreamWriter($client)
        $writer.AutoFlush = $true
        $writer.WriteLine($Message)
        $reader = New-Object System.IO.StreamReader($client)
        $response = $reader.ReadLine()
        return $response
    }
    catch {
        Write-Error "Failed to connect to claude-ctl server: $_"
        return $null
    }
    finally {
        if ($client) { $client.Dispose() }
    }
}

# ============================================================
# Server Mode (runs as background process, holds ConPTY open)
# ============================================================

function Start-Server {
    # Log server output to file (since this runs in a hidden window)
    $serverLog = Join-Path $script:ProjectRoot "logs\server.log"
    Start-Transcript -Path $serverLog -Force | Out-Null

    Ensure-ConPtyLoaded

    $workDir = $script:ProjectRoot
    $claudeCmd = if ($env:CLAUDE_CMD) { $env:CLAUDE_CMD } else { "claude --dangerously-skip-permissions" }

    # Enable ConPTY log by default (can be overridden by CONPTY_LOG env var)
    if (-not $env:CONPTY_LOG) {
        $env:CONPTY_LOG = $script:LogFile
    }
    Write-Host "ConPTY log: $($env:CONPTY_LOG)"

    Write-Host "Starting Claude in ConPTY..."
    $childPid = [ConPtyHelper]::Start($claudeCmd, $workDir)
    Write-Host "Claude PID: $childPid"

    # Save child PID
    $childPid | Out-File -FilePath $script:PidFile -Encoding ASCII -NoNewline

    # Wait for Claude to initialize, handling prompts based on buffer content.
    # Each prompt is identified by its text, and the correct key sequence is sent.
    # After handling, the buffer is cleared so the next prompt can be detected.
    Write-Host "Waiting for Claude to initialize..."
    $initWait = 0
    $promptsHandled = 0
    while ($initWait -lt 60 -and [ConPtyHelper]::IsRunning()) {
        Start-Sleep -Seconds 2
        $initWait += 2
        $buf = [ConPtyHelper]::GetOutput()

        if ($buf.Length -gt 0) {
            Write-Host "  [$initWait s] Buffer ($($buf.Length) chars): $($buf.Substring([Math]::Max(0, $buf.Length - 200)))" -ForegroundColor DarkGray
        }

        # Check if TUI is ready (input prompt visible)
        if ($buf -match "Claude Code" -or $buf -match "What can I help") {
            Write-Host "Claude TUI is ready. (handled $promptsHandled prompt(s))"
            Start-Sleep -Seconds 2
            break
        }

        # Detect and handle known prompts by their content
        $handled = $false

        # Pattern: any selection prompt with "Yes" option (folder trust, ToS, etc.)
        # These typically have "Yes" as default (top) selection, so Enter accepts.
        if ($buf -match "trust" -or $buf -match "Trust" -or $buf -match "accept" -or $buf -match "Accept") {
            $promptsHandled++
            Write-Host "  Prompt #$promptsHandled detected (trust/accept). Sending Enter..."
            [ConPtyHelper]::SendEnter()
            $handled = $true
        }
        # Pattern: "No, exit" visible - the decline option.
        # Need to determine if cursor is on Yes or No.
        # If "Yes" has the selection marker (❯ or >) before it, just Enter.
        # Otherwise send Arrow Up to go to Yes, then Enter.
        elseif ($buf -match "No, exit") {
            $promptsHandled++
            if ($buf -match "❯.*Yes" -or $buf -match ">.*Yes") {
                Write-Host "  Prompt #$promptsHandled detected (No,exit visible, Yes selected). Sending Enter..."
                [ConPtyHelper]::SendEnter()
            } else {
                # Cursor might be on No. Try Arrow Up to reach Yes, then Enter.
                Write-Host "  Prompt #$promptsHandled detected (No,exit visible, navigating to Yes). Sending Up+Enter..."
                [ConPtyHelper]::SendInput([char]0x1B + "[A")  # Arrow Up
                Start-Sleep -Milliseconds 300
                [ConPtyHelper]::SendEnter()
            }
            $handled = $true
        }

        if ($handled) {
            Start-Sleep -Seconds 3
            [ConPtyHelper]::ClearOutput()
        }
    }

    Write-Host "Named pipe server starting on: $script:PipeName"

    # Main IPC loop
    try {
        while ([ConPtyHelper]::IsRunning()) {
            $server = $null
            try {
                $server = New-Object System.IO.Pipes.NamedPipeServerStream($script:PipeName, [System.IO.Pipes.PipeDirection]::InOut, 1)
                # Wait for connection with timeout (poll every 2s to check process)
                while (-not $server.IsConnected) {
                    $ar = $server.BeginWaitForConnection($null, $null)
                    if ($ar.AsyncWaitHandle.WaitOne(2000)) {
                        try { $server.EndWaitForConnection($ar) } catch [System.InvalidOperationException] { }
                    }
                    else {
                        if (-not [ConPtyHelper]::IsRunning()) {
                            Write-Host "Claude process exited."
                            break
                        }
                    }
                }

                if (-not $server.IsConnected) { break }

                $reader = New-Object System.IO.StreamReader($server)
                $writer = New-Object System.IO.StreamWriter($server)
                $writer.AutoFlush = $true

                $line = $reader.ReadLine()
                if ($null -eq $line) { continue }
                $line = $line.Trim()

                switch -Regex ($line) {
                    "^SEND:(.+)$" {
                        $text = $Matches[1]
                        [ConPtyHelper]::SendLine($text)
                        $writer.WriteLine("OK")
                    }
                    "^ENTER$" {
                        [ConPtyHelper]::SendEnter()
                        $writer.WriteLine("OK")
                    }
                    "^STATUS$" {
                        $running = [ConPtyHelper]::IsRunning()
                        $writer.WriteLine($(if ($running) { "RUNNING" } else { "STOPPED" }))
                    }
                    "^GETLOG$" {
                        $buf = [ConPtyHelper]::GetOutput()
                        # Replace newlines with escape sequence for pipe transport
                        $escaped = $buf -replace "`r`n", "<<NL>>" -replace "`n", "<<NL>>" -replace "`r", "<<NL>>"
                        $writer.WriteLine($escaped)
                    }
                    "^KILL$" {
                        [ConPtyHelper]::Kill()
                        $writer.WriteLine("OK")
                        Start-Sleep -Milliseconds 500
                        break
                    }
                    default {
                        $writer.WriteLine("ERR:Unknown command")
                    }
                }
            }
            catch [System.IO.IOException] {
                # Client disconnected, continue loop
            }
            finally {
                if ($server) { $server.Dispose() }
            }
        }
    }
    finally {
        Write-Host "Shutting down ConPTY..."
        [ConPtyHelper]::Kill()
        [ConPtyHelper]::Close()
        Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue
        Remove-Item $script:ServerPidFile -Force -ErrorAction SilentlyContinue
        Write-Host "Done."
        try { Stop-Transcript | Out-Null } catch { }
    }
}

# ============================================================
# Client Commands
# ============================================================

function Invoke-Start {
    # Kill existing if running
    Invoke-Kill 2>$null

    # Ensure logs dir exists
    $logsDir = Join-Path $script:ProjectRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

    # Launch server as background process.
    # IMPORTANT: Do NOT use -RedirectStandardOutput/-RedirectStandardError here.
    # Redirecting stdin/stdout causes Claude CLI to detect non-interactive mode
    # and fail with "Input must be provided through stdin or as a prompt argument".
    # Server writes its own log to logs/server.log via Start-Transcript instead.
    $scriptPath = $PSCommandPath
    $proc = Start-Process -FilePath $script:PwshPath -ArgumentList "-NoProfile", "-File", $scriptPath, "server" `
        -WorkingDirectory $script:ProjectRoot `
        -WindowStyle Hidden `
        -PassThru

    $proc.Id | Out-File -FilePath $script:ServerPidFile -Encoding ASCII -NoNewline

    Write-Host "Server started (PID: $($proc.Id)). Waiting for Claude to initialize..."

    # Wait for the named pipe to become available
    $waited = 0
    while ($waited -lt 30) {
        Start-Sleep -Seconds 1
        $waited++
        try {
            $response = Send-PipeCommand "STATUS"
            if ($response -eq "RUNNING") {
                Write-Host "Claude is ready."
                return
            }
        }
        catch { }
    }

    # Show server logs on failure for debugging
    $serverLog = Join-Path $script:ProjectRoot "logs\server.log"
    if (Test-Path $serverLog) {
        Write-Host "--- server.log (last 30 lines) ---"
        Get-Content $serverLog -Tail 30 | ForEach-Object { Write-Host $_ }
    }
    Write-Error "Timeout: Claude did not start within 30 seconds."
}

function Invoke-Send {
    param([string]$SendText)
    if (-not $SendText) {
        Write-Error "Usage: claude-ctl.ps1 send <text>"
        return
    }
    $response = Send-PipeCommand "SEND:$SendText"
    if ($response -ne "OK") {
        Write-Error "Send failed: $response"
    }
}

function Invoke-Enter {
    $response = Send-PipeCommand "ENTER"
    if ($response -ne "OK") {
        Write-Error "Enter failed: $response"
    }
}

function Invoke-Wait {
    param([int]$WaitTimeout = 3600)

    $startTime = Get-Date
    $timeoutSpan = New-TimeSpan -Seconds $WaitTimeout

    Write-Host "Waiting for .claude_done (timeout: ${WaitTimeout}s)..."

    while ((Get-Date) - $startTime -lt $timeoutSpan) {
        if (Test-Path $script:DoneFile) {
            Write-Host "Signal received: .claude_done"
            return $true
        }
        # Send Enter to keep Claude responsive
        try { Send-PipeCommand "ENTER" | Out-Null } catch { }
        Start-Sleep -Seconds 30
    }

    Write-Warning "Timeout: .claude_done not received within ${WaitTimeout}s"
    return $false
}

function Invoke-Kill {
    # Try graceful shutdown via pipe
    try { Send-PipeCommand "KILL" | Out-Null } catch { }

    # Kill server process if still alive
    if (Test-Path $script:ServerPidFile) {
        $serverPid = Get-Content $script:ServerPidFile -Raw
        try {
            Stop-Process -Id ([int]$serverPid) -Force -ErrorAction SilentlyContinue
        }
        catch { }
        Remove-Item $script:ServerPidFile -Force -ErrorAction SilentlyContinue
    }

    # Kill Claude process if still alive
    if (Test-Path $script:PidFile) {
        $claudePid = Get-Content $script:PidFile -Raw
        try {
            Stop-Process -Id ([int]$claudePid) -Force -ErrorAction SilentlyContinue
        }
        catch { }
        Remove-Item $script:PidFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Claude worker stopped."
}

function Invoke-Status {
    try {
        $response = Send-PipeCommand "STATUS"
        if ($response -eq "RUNNING") {
            Write-Host "Claude is running."
            exit 0
        }
        else {
            Write-Host "Claude is not running."
            exit 1
        }
    }
    catch {
        Write-Host "Claude is not running (server unreachable)."
        exit 1
    }
}

function Invoke-Log {
    # Show ConPTY output buffer (live state from server) + log file tail
    Write-Host "=== ConPTY Live Buffer (last 8KB) ==="
    try {
        $response = Send-PipeCommand "GETLOG"
        if ($response) {
            $decoded = $response -replace "<<NL>>", "`n"
            # Strip ANSI escape sequences for readability
            $clean = $decoded -replace '\x1b\[[0-9;]*[a-zA-Z]', '' -replace '\x1b\][^\x07]*\x07', '' -replace '\x1b[()][0-9A-Z]', ''
            Write-Host $clean
        }
        else {
            Write-Host "(empty)"
        }
    }
    catch {
        Write-Host "(server unreachable - showing log file instead)"
    }

    Write-Host ""
    Write-Host "=== Log File: $script:LogFile ==="
    if (Test-Path $script:LogFile) {
        # Show last 100 lines, strip ANSI sequences
        $lines = Get-Content $script:LogFile -Tail 100 -ErrorAction SilentlyContinue
        if ($lines) {
            $raw = $lines -join "`n"
            $clean = $raw -replace '\x1b\[[0-9;]*[a-zA-Z]', '' -replace '\x1b\][^\x07]*\x07', '' -replace '\x1b[()][0-9A-Z]', ''
            Write-Host $clean
        }
        else {
            Write-Host "(empty)"
        }
    }
    else {
        Write-Host "(log file not found: $script:LogFile)"
    }
}

# ============================================================
# Main Dispatch
# ============================================================

switch ($Command) {
    "start"  { Invoke-Start }
    "send"   { Invoke-Send -SendText $Text }
    "enter"  { Invoke-Enter }
    "wait"   { Invoke-Wait -WaitTimeout $Timeout }
    "kill"   { Invoke-Kill }
    "status" { Invoke-Status }
    "log"    { Invoke-Log }
    "server" { Start-Server }
    default  {
        Write-Host "Usage: claude-ctl.ps1 <start|send|enter|wait|kill|status|log> [args]"
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  start              Launch Claude in ConPTY background process"
        Write-Host "  send <text>        Send text + Enter to Claude"
        Write-Host "  enter              Send Enter key only"
        Write-Host "  wait [-Timeout N]  Wait for .claude_done signal (default: 3600s)"
        Write-Host "  kill               Stop Claude and cleanup"
        Write-Host "  status             Check if Claude is running"
        Write-Host "  log                Show Claude ConPTY output (live buffer + log file)"
    }
}
