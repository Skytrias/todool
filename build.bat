@echo off
rem odin.exe run src -out:todool.exe
odin.exe build src -out:target/todool.exe && pushd target && todool.exe && popd
rem ..\Odin\odin.exe check src
rem odin.exe build src -o:speed -out:target/todool.exe && pushd target && todool.exe && popd