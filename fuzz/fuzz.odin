package fuzz

import "core:unicode"
import "core:unicode/utf8"

SCORE_MATCH :: 16
SCORE_GAP_START :: -3
SCORE_GAP_EXTENSION :: -1
BONUS_BOUNDARY :: SCORE_MATCH / 2
BONUS_NON_WORD :: BONUS_BOUNDARY
BONUS_CAMEL_123 :: BONUS_BOUNDARY + SCORE_GAP_EXTENSION
BONUS_CONSECUTIVE :: -(SCORE_GAP_START + SCORE_GAP_EXTENSION)
BONUS_FIRST_CHAR_MULTIPLIER :: 2

Fuzz_Result :: struct {
	// byte offsets
	start, end: int,
	score: int,
}

// continuation byte?
@private
is_cont :: proc(b: byte) -> bool {
	return b & 0xc0 == 0x80
}

@private
utf8_prev :: proc(bytes: string, a, b: int) -> int {
	b := b

	for a < b && is_cont(bytes[b - 1]) {
		b -= 1
	}

	return a < b ? b - 1 : a
}

@private
utf8_next :: proc(bytes: string, a: int) -> int {
	a := a
	b := len(bytes)

	for a < b - 1 && is_cont(bytes[a + 1]) {
		a += 1
	}

	return a < b ? a + 1 : b
}

utf8_peek :: utf8.decode_rune_in_string

@private
fuzz_calculate_score :: proc(
	trunes, prunes: string, 
	sidx, eidx: int, 
	case_sensitive: bool,
) -> int {
	pidx, score, consecutive, first_bonus: int 
	in_gap: bool
	//prev_class := '';
	
	if sidx > 0 {
		//prev_class = trunes[sidx - 1];
	}
	
	for idx := sidx; idx < eidx; {
	// for idx := sidx; idx < eidx; idx += 1 {
		schar, size := utf8_peek(trunes[idx:])
		defer idx += size
		// c := trunes[idx]

		if !case_sensitive {
			schar = unicode.to_lower(schar)
		}
		
		pchar, _ := utf8_peek(prunes[pidx:])
		if schar == pchar {
			score += SCORE_MATCH
			//bonus := bonusFor(prevClass, class)
			bonus := 0
			
			if consecutive == 0 {
				first_bonus = bonus
			} else {
				// break consecutive chunk
				if bonus == BONUS_BOUNDARY {
					first_bonus = bonus
				}
				
				bonus = max(max(bonus, first_bonus), BONUS_CONSECUTIVE)
			}
			
			if pidx == 0 {
				score += bonus * BONUS_FIRST_CHAR_MULTIPLIER;
			} else {
				score += bonus
			}
			
			in_gap = false
			consecutive += 1
			pidx += 1 
		} else {
			if in_gap {
				score += SCORE_GAP_EXTENSION
			} else {
				score += SCORE_GAP_START
			}
			
			in_gap = true
			consecutive = 0
			first_bonus = 0
		}
		
		//prev_class = class
	}
	
	return score
}

match :: fuzz_match_v1

fuzz_match_v1 :: proc(
	haystack, pattern: string, 
	case_sensitive := false,
) -> (res: Fuzz_Result, ok: bool) {
	if len(pattern) == 0 {
		return
	}
	
	pidx := 0
	sidx := -1
	eidx := -1
	
	for index := 0; index < len(haystack); {
		schar, ssize := utf8_peek(haystack[index:])
		defer index += ssize

		// if !case_sensitive {
		// 	c = unicode.to_lower(c)
		// }

		pchar, psize := utf8_peek(pattern[pidx:])
		
		if schar == pchar {
			if sidx < 0 {
				sidx = index
			}
			
			pidx += psize
			
			if pidx == len(pattern) {
				eidx = index + ssize
				break
			}
		}
	}
	
	if sidx >= 0 && eidx >= 0 {
		pidx = utf8_prev(pattern, 0, pidx)
		
		for index := utf8_prev(haystack, 0, eidx); index >= sidx; {
			schar, _ := utf8_peek(haystack[index:])

			// if !case_sensitive {
			// 	c = unicode.to_lower(c)
			// }
			
			pchar, _ := utf8_peek(pattern[pidx:])
			
			if schar == pchar {
				pidx = utf8_prev(pattern, 0, pidx)
				
				if pidx < 0 {
					sidx = index
					break
				}
			}
			
			// stop at last index
			if index == 0 {
				break
			}

			index = utf8_prev(haystack, 0, index)
		}
		
		score := fuzz_calculate_score(haystack, pattern, sidx, eidx, case_sensitive)
		res = { sidx, eidx, score }
		ok = true
		return
	}
	
	return
}