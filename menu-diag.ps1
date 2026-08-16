# menu-diag.ps1 — 菜单读键问题诊断（临时脚本，定位后删除）
# 用法：irm https://raw.githubusercontent.com/likangdi-code/clash-verge-url-proxy-cli/<commit>/menu-diag.ps1 | iex
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== 0. 环境 ===' -ForegroundColor Cyan
Write-Host "PS 版本: $($PSVersionTable.PSVersion)   Host: $($Host.Name)   WT_SESSION: $($env:WT_SESSION)"
try { Write-Host "Console.IsInputRedirected: $([Console]::IsInputRedirected)" } catch { Write-Host "IsInputRedirected EXC: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== 1. Add-Type 编译 Win32 封装 ===' -ForegroundColor Cyan
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClashConInDiag {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetNumberOfConsoleInputEvents(IntPtr hConsoleInput, out uint lpNumberOfEvents);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool ReadConsoleInput(IntPtr hConsoleInput, out INPUT_RECORD lpBuffer, uint nLength, out uint lpNumberOfEventsRead);
    [StructLayout(LayoutKind.Sequential)] public struct KEY_EVENT_RECORD {
        public bool bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode; public char UnicodeChar; public uint dwControlKeyState;
    }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT_RECORD {
        public ushort EventType; public KEY_EVENT_RECORD KeyEvent;
    }
    public static IntPtr Handle() { return GetStdHandle(-10); }
    public static bool HasInput() {
        IntPtr h = GetStdHandle(-10);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) return false;
        uint n; return GetNumberOfConsoleInputEvents(h, out n) && n > 0;
    }
    public static int ReadKeyVk() {
        IntPtr h = GetStdHandle(-10);
        INPUT_RECORD r; uint read;
        while (true) {
            if (!ReadConsoleInput(h, out r, 1, out read) || read == 0) return 0;
            if (r.EventType == 1 && r.KeyEvent.bKeyDown) return r.KeyEvent.wVirtualKeyCode;
        }
    }
}
'@ -ErrorAction Stop
    Write-Host "编译 OK"
} catch { Write-Host "编译 FAIL: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== 2. 控制台句柄 ===' -ForegroundColor Cyan
try {
    $h = [ClashConInDiag]::Handle()
    Write-Host "GetStdHandle(-10) = $h  (INVALID=$([intptr]::new(-1)))"
    Write-Host "HasInput 初值: $([ClashConInDiag]::HasInput())"
} catch { Write-Host "EXC: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== 3. 请现在按 ↑ 或 ↓ 键（3 秒窗口）===' -ForegroundColor Yellow
$saw = $false
$deadline = [DateTime]::Now.AddSeconds(3)
try {
    while ([DateTime]::Now -lt $deadline) {
        if ([ClashConInDiag]::HasInput()) { $saw = $true; break }
        Start-Sleep -Milliseconds 50
    }
    Write-Host "Win32 检测到按键: $saw"
    if ($saw) {
        $vk = [ClashConInDiag]::ReadKeyVk()
        Write-Host "Win32 读到 VK=$vk"
    }
} catch { Write-Host "Win32 EXC: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== 4. .NET Console.KeyAvailable ===' -ForegroundColor Cyan
try { Write-Host "值: $([Console]::KeyAvailable)" } catch { Write-Host "EXC: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== 5. RawUI.KeyAvailable ===' -ForegroundColor Cyan
try { Write-Host "值: $($Host.UI.RawUI.KeyAvailable)" } catch { Write-Host "EXC: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== 诊断完成，请把以上输出全部复制发回 ===' -ForegroundColor Green
