@echo off
setlocal

if "%~1"=="" (
set /p msg="Enter message: "
) else (
set msg=%*
rem set msg=%msg:\"=%
)

set msg=%msg:"=%

git add .
git commit -m "%msg%"
git pull
git push
