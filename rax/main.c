#include <stddef.h>
#include "rax.h"
#include "rax.c"

typedef struct raxFindResult {
	void* data;
	int valid;
} raxFindResult;

raxFindResult raxCustomFind(rax *rax, unsigned char *s, size_t len) {
	void* data = raxFind(rax, s, len);
	raxFindResult res = {
		data,
		data != raxNotFound,
	};
	return res;
}