@echo off
..\Odin\odin.exe build src -subsystem:windows -o:speed -thread-count:12 -out:target/todool.exe -resource:target/todool.rc