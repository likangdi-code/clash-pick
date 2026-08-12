@echo off
rem clash-dl: standalone multi-threaded downloader (proxy/direct), wraps clash-pick dl
node "%~dp0clash-pick.mjs" dl %*
