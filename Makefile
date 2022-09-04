# 	@../Odin/odin check src -thread-count:12	

build:
	@../Odin/odin build src -out:target/todool -thread-count:12 && cd target && ./todool

release:
	@../Odin/odin build src -out:target/todool -o:speed -thread-count:12

debug: 
	@../Odin/odin build src -out:target/todool -debug -thread-count:12

run:
	@cd target && ./todool

check:
	@../Odin/odin check src -thread-count:12