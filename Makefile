build:
	@../Odin/odin run src -out:todool -thread-count:12
# 	@../Odin/odin check src -thread-count:12	
		
release:
	@../Odin/odin build src -out:todool -o:speed -thread-count:12

debug: 
	@../Odin/odin build src -out:todool -debug -thread-count:12

run:
	@cd target && ./todool

check:
	@../Odin/odin check src -thread-count:12	