@echo off
odin.exe build src -out:target/todool.exe -thread-count:12 && pushd target && todool.exe && popd
