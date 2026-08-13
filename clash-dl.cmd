@echo off
rem clash-dl: standalone multi-threaded downloader (proxy/direct), wraps clash-proxy dl
node "%~dp0clash-proxy.mjs" dl %*
