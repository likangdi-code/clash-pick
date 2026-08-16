# menu-diag.ps1 — 菜单读键问题诊断 v2（临时脚本，定位后删除）
# 用法：irm https://raw.githubusercontent.com/likangdi-code/clash-verge-url-proxy-cli/<commit>/menu-diag.ps1 | iex
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host '=== 0. 环境与残留检查 ===' -ForegroundColor Cyan
Write-Host "PS 版本: $($PSVersionTable.PSVersion)   Host: $($Host.Name)"
$old = [AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object {
    try { $_.GetTypes() | Where-Object { $_.Name -like 'ClashConIn*' } } catch {}
}
Write-Host "已加载旧类型: $(if ($old) { ($old | ForEach-Object { $_.FullName }) -join '; ' } else { '无' })"
Write-Host "CLASH_PROXY_MENU_TIMEOUT: [$env:CLASH_PROXY_MENU_TIMEOUT]"
try { Write-Host "Console.IsInputRedirected: $([Console]::IsInputRedirected)" } catch { Write-Host "IsInputRedirected EXC: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== 1. 编译（唯一类型名 ClashConInD2）===' -ForegroundColor Cyan
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClashConInD2 {
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
    public static bool HasInput() {
        IntPtr h = GetStdHandle(-10);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) return false;
        uint n; return GetNumberOfConsoleInputEvents(h, out n) && n > 0;
    }
    public static int ReadKeyVk() {
        IntPtr h = GetStdHandle(-10);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) return 0;
        uint n;
        if (!GetNumberOfConsoleInputEvents(h, out n) || n == 0) return 0;
        INPUT_RECORD r; uint read;
        for (uint i = 0; i < n; i++) {
            if (!ReadConsoleInput(h, out r, 1, out read) || read == 0) return 0;
            if (r.EventType == 1 && r.KeyEvent.bKeyDown) return r.KeyEvent.wVirtualKeyCode;
        }
        return 0;
    }
    public static void FlushInput() {
        IntPtr h = GetStdHandle(-10);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) return;
        uint n;
        if (!GetNumberOfConsoleInputEvents(h, out n) || n == 0) return;
        INPUT_RECORD r; uint read;
        for (uint i = 0; i < n; i++) ReadConsoleInput(h, out r, 1, out read);
    }
}
'@ -ErrorAction Stop
    Write-Host "编译 OK"
} catch { Write-Host "编译 FAIL: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== 2. FlushInput 计时（应 <1s 返回）===' -ForegroundColor Cyan
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [ClashConInD2]::FlushInput()
    $sw.Stop()
    Write-Host "Flush 返回，耗时 $($sw.ElapsedMilliseconds) ms（>1000ms = 阻塞 bug）"
} catch { Write-Host "Flush EXC: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== 3. 复刻菜单读键循环（8 秒窗口）===' -ForegroundColor Yellow
Write-Host '请在这 8 秒内按 ↑ 或 ↓ 键：'
try {
    $deadline = [DateTime]::Now.AddSeconds(8)
    $key = 0
    $seen = @()
    while ([DateTime]::Now -lt $deadline) {
        if ([ClashConInD2]::HasInput()) {
            $k = [ClashConInD2]::ReadKeyVk()
            if ($k -ne 0) {
                $seen += $k
                Write-Host "读到 VK=$k"
                $deadline = [DateTime]::Now.AddSeconds(2)  # 再给 2s 收尾
            }
        } else { Start-Sleep -Milliseconds 100 }
    }
    if (-not $seen) { Write-Host '未读到任何按键' }
    else { Write-Host "共读到: $($seen -join ',')" }
} catch { Write-Host "读键 EXC: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== 4. .NET Console.KeyAvailable / RawUI.KeyAvailable ===' -ForegroundColor Cyan
try { Write-Host "Console.KeyAvailable: $([Console]::KeyAvailable)" } catch { Write-Host "Console EXC: $($_.Exception.Message)" }
try { Write-Host "RawUI.KeyAvailable: $($Host.UI.RawUI.KeyAvailable)" } catch { Write-Host "RawUI EXC: $($_.Exception.Message)" }

Write-Host ''
Write-Host '=== 诊断完成，请把以上输出全部复制发回 ===' -ForegroundColor Green
