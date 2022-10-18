#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <mmintrin.h>
#include <xmmintrin.h>
#include <emmintrin.h>

// testing this out testing this out testing this out testing this out
// 
// TEST
// T = testing this out testing this out testing this out testing this out
// pattern = test
// A = testing this out testing this ou
// B = testtesttesttesttesttesttesttest

int sse2_strstr(const char* s, size_t n, const char* needle, size_t k) {
	const __m128i first = _mm_set1_epi8(needle[0]);
	const __m128i last  = _mm_set1_epi8(needle[k - 1]);

	for (size_t i = 0; i < n; i += 32) {
		const __m128i block_first = _mm_loadu_si128((const __m128i*)(s + i));
		const __m128i block_last  = _mm_loadu_si128((const __m128i*)(s + i + k - 1));

		const __m128i eq_first = _mm_cmpeq_epi8(first, block_first);
		const __m128i eq_last  = _mm_cmpeq_epi8(last, block_last);

		uint32_t mask = _mm_movemask_epi8(_mm_and_si128(eq_first, eq_last));

		if (mask != 0) {
			return 1;
		}

		// while (mask != 0) {
		// 	const auto bitpos = bits::get_first_bit_set(mask);

		// 	if (memcmp(s + i + bitpos + 1, needle + 1, k - 2) == 0) {
		// 			return i + bitpos;
		// 	}

		// 	mask = bits::clear_leftmost_set(mask);
		// }
	}

	return 0;
}

#include <time.h>

static void print_time_us(const char* name, void(*fn)(void)) {
	struct timespec start, end;
	clock_gettime(CLOCK_MONOTONIC_RAW, &start);
	fn();
	clock_gettime(CLOCK_MONOTONIC_RAW, &end);
	uint64_t delta_us = (end.tv_sec - start.tv_sec) * 1000000 + (end.tv_nsec - start.tv_nsec) / 1000;
	printf("Running: '%s' took %lu u/s\n", name, delta_us);
}

void test() {
	const char* s1 = "// TODO testing this out";
	const char* s2 = "// TODO";
	int res = sse2_strstr(s1, strlen(s1), s2, strlen(s2));
	// printf("yo %d\n", res);
}

void test_simple() {
	const char* s1 = "/home/skytrias/Downloads/essence-master/desktop/gui.cpp"
	const char* s2 = "// TODO";
	int res = sse2_strstr(s1, strlen(s1), s2, strlen(s2));
}

int main() {
	print_time_us("test", test);
}